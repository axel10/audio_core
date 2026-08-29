import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'audio_stream_cache_manager.dart';

/// Lightweight loopback HTTP proxy server for streaming remote audio with progressive caching.
class AudioStreamCacheProxy {
  final AudioStreamCacheManager cacheManager;
  HttpServer? _server;
  int? _port;
  Completer<int>? _startingCompleter;
  final HttpClient _httpClient = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..idleTimeout = const Duration(seconds: 60)
    ..badCertificateCallback = ((cert, host, port) => true)
    ..autoUncompress = false;

  AudioStreamCacheProxy({AudioStreamCacheManager? cacheManager})
      : cacheManager = cacheManager ?? AudioStreamCacheManager();

  int? get port => _port;
  bool get isRunning => _server != null;

  static Uri safeParseUri(String url) {
    try {
      final parsed = Uri.parse(url);
      if (parsed.hasScheme && parsed.hasAuthority) {
        if (url.contains(' ') || url.contains('[') || url.contains(']')) {
          return Uri.parse(Uri.encodeFull(url));
        }
        return parsed;
      }
    } catch (_) {}
    return Uri.parse(Uri.encodeFull(url));
  }

  /// Starts the local HTTP proxy server on a random loopback port.
  Future<int> start() async {
    if (_server != null) {
      return _port!;
    }
    if (_startingCompleter != null) {
      return _startingCompleter!.future;
    }
    final completer = Completer<int>();
    _startingCompleter = completer;
    try {
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _port = _server!.port;
      _server!.listen(_handleRequest, onError: (e) {
        debugPrint('[AudioStreamCacheProxy] Server error: $e');
      });
      debugPrint('[AudioStreamCacheProxy] Started listening on 127.0.0.1:$_port');
      completer.complete(_port!);
      return _port!;
    } catch (e, stack) {
      completer.completeError(e, stack);
      rethrow;
    } finally {
      _startingCompleter = null;
    }
  }

  /// Stops the proxy server.
  Future<void> stop() async {
    if (_server != null) {
      await _server!.close(force: true);
      _server = null;
      _port = null;
      debugPrint('[AudioStreamCacheProxy] Proxy stopped.');
    }
  }

  /// Builds a playable local proxy URL for a remote audio stream.
  String buildProxyUrl({
    required String remoteUrl,
    Map<String, String>? headers,
    String? cacheKey,
  }) {
    if (_port == null) {
      throw StateError('Proxy server is not started yet. Call start() first.');
    }
    final uri = Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: _port,
      path: '/stream',
      queryParameters: {
        'url': remoteUrl,
        if (headers != null && headers.isNotEmpty)
          'headers': Uri.encodeComponent(
            headers.entries.map((e) => '${e.key}:${e.value}').join('||'),
          ),
        if (cacheKey != null && cacheKey.isNotEmpty) 'cacheKey': cacheKey,
      },
    );
    return uri.toString();
  }

  final Map<String, Future<File>> _activePrefetches = {};

  /// Eagerly triggers background caching for a track if not already cached.
  Future<File>? ensureBackgroundPrefetch({
    required String targetUrl,
    Map<String, String>? headers,
    required String cacheKey,
  }) {
    if (_activePrefetches.containsKey(cacheKey)) {
      return _activePrefetches[cacheKey];
    }

    final future = _doBackgroundPrefetch(
      targetUrl: targetUrl,
      headers: headers,
      cacheKey: cacheKey,
    );
    _activePrefetches[cacheKey] = future;
    return future;
  }

  Future<File> _doBackgroundPrefetch({
    required String targetUrl,
    Map<String, String>? headers,
    required String cacheKey,
  }) async {
    try {
      final cached = await cacheManager.ensureTrackCached(
        cacheKey: cacheKey,
        remoteUrl: safeParseUri(targetUrl).toString(),
        headers: headers,
      );
      debugPrint('[AudioStreamCacheProxy] Background prefetch completed for $cacheKey -> ${cached.path}');
      return cached;
    } catch (e) {
      debugPrint('[AudioStreamCacheProxy] Background prefetch failed for $cacheKey: $e');
      rethrow;
    } finally {
      _activePrefetches.remove(cacheKey);
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final path = request.uri.path;
    if (path == '/ping' || path == '/health') {
      request.response
        ..statusCode = HttpStatus.ok
        ..write('OK')
        ..close();
      return;
    }

    if (path != '/stream') {
      request.response
        ..statusCode = HttpStatus.notFound
        ..write('Not Found')
        ..close();
      return;
    }

    final targetUrl = request.uri.queryParameters['url'];
    if (targetUrl == null || targetUrl.isEmpty) {
      request.response
        ..statusCode = HttpStatus.badRequest
        ..write('Missing "url" query parameter')
        ..close();
      return;
    }

    final rawHeaders = request.uri.queryParameters['headers'];
    final upstreamHeaders = <String, String>{};
    if (rawHeaders != null && rawHeaders.isNotEmpty) {
      final decoded = Uri.decodeComponent(rawHeaders);
      for (final part in decoded.split('||')) {
        final idx = part.indexOf(':');
        if (idx > 0) {
          final k = part.substring(0, idx).trim();
          final v = part.substring(idx + 1).trim();
          upstreamHeaders[k] = v;
        }
      }
    }

    final cacheKey = request.uri.queryParameters['cacheKey'] ?? targetUrl;

    try {
      final isCached = await cacheManager.isTrackCached(cacheKey);
      if (isCached) {
        final file = await cacheManager.getCacheFile(cacheKey);
        await _serveLocalFile(request, file);
        return;
      }

      // Eagerly trigger background prefetch so the full file is downloaded rapidly in the background
      unawaited(
        ensureBackgroundPrefetch(
          targetUrl: targetUrl,
          headers: upstreamHeaders,
          cacheKey: cacheKey,
        ),
      );

      await _proxyUpstreamRequest(request, targetUrl, upstreamHeaders, cacheKey);
    } catch (e, stack) {
      debugPrint('[AudioStreamCacheProxy] Error handling stream request: $e\n$stack');
      try {
        request.response
          ..statusCode = HttpStatus.internalServerError
          ..write('Proxy Error: $e')
          ..close();
      } catch (_) {}
    }
  }

  Future<void> _serveLocalFile(HttpRequest request, File file) async {
    await cacheManager.touchCacheFile(file);
    final totalLength = await file.length();
    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);

    request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    request.response.headers.set(HttpHeaders.contentTypeHeader, 'audio/mpeg');

    if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
      final rangeStr = rangeHeader.substring(6).trim();
      final parts = rangeStr.split('-');
      final start = int.tryParse(parts[0]) ?? 0;
      final end = parts.length > 1 && parts[1].isNotEmpty
          ? (int.tryParse(parts[1]) ?? totalLength - 1)
          : totalLength - 1;

      final boundedStart = start.clamp(0, totalLength - 1);
      final boundedEnd = end.clamp(boundedStart, totalLength - 1);
      final contentLength = boundedEnd - boundedStart + 1;

      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $boundedStart-$boundedEnd/$totalLength',
      );
      request.response.headers.set(
        HttpHeaders.contentLengthHeader,
        contentLength,
      );

      final stream = file.openRead(boundedStart, boundedEnd + 1);
      await request.response.addStream(stream);
      await request.response.close();
    } else {
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.set(HttpHeaders.contentLengthHeader, totalLength);
      await request.response.addStream(file.openRead());
      await request.response.close();
    }
  }

  Future<void> _proxyUpstreamRequest(
    HttpRequest request,
    String targetUrl,
    Map<String, String> upstreamHeaders,
    String cacheKey,
  ) async {
    final clientRangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    final upstreamUri = safeParseUri(targetUrl);

    final HttpClientRequest upstreamReq;
    try {
      upstreamReq = await _httpClient.getUrl(upstreamUri);
    } catch (e) {
      debugPrint('[AudioStreamCacheProxy] Failed to connect to upstream $upstreamUri: $e');
      try {
        request.response
          ..statusCode = HttpStatus.badGateway
          ..write('Bad Gateway: $e')
          ..close();
      } catch (_) {}
      return;
    }

    // Forward upstream headers
    upstreamHeaders.forEach((k, v) {
      upstreamReq.headers.set(k, v);
    });

    if (clientRangeHeader != null) {
      upstreamReq.headers.set(HttpHeaders.rangeHeader, clientRangeHeader);
    }

    final HttpClientResponse upstreamResp;
    try {
      upstreamResp = await upstreamReq.close();
    } catch (e) {
      debugPrint('[AudioStreamCacheProxy] Upstream response error from $upstreamUri: $e');
      try {
        request.response
          ..statusCode = HttpStatus.badGateway
          ..write('Bad Gateway: $e')
          ..close();
      } catch (_) {}
      return;
    }

    final statusCode = upstreamResp.statusCode;
    request.response.statusCode = statusCode;

    // Forward relevant headers
    for (final header in [
      HttpHeaders.contentTypeHeader,
      HttpHeaders.contentLengthHeader,
      HttpHeaders.contentRangeHeader,
      HttpHeaders.acceptRangesHeader,
    ]) {
      final val = upstreamResp.headers.value(header);
      if (val != null) {
        request.response.headers.set(header, val);
      }
    }

    if (request.response.headers.value(HttpHeaders.acceptRangesHeader) == null) {
      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    }

    var chunkCount = 0;
    try {
      await for (final chunk in upstreamResp) {
        try {
          request.response.add(chunk);
          if (chunkCount++ < 5) {
            await request.response.flush();
          }
        } catch (_) {
          break;
        }
      }
    } catch (_) {}

    try {
      await request.response.close();
    } catch (_) {}
  }
}
