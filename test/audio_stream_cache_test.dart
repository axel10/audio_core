import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:audio_core/audio_core.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late AudioStreamCacheManager cacheManager;

  setUp(() async {
    HttpOverrides.global = null;
    tempDir = await Directory.systemTemp.createTemp('audio_stream_cache_test_');
    cacheManager = AudioStreamCacheManager(
      customCacheDirectory: tempDir,
      maxCacheSizeBytesGetter: () => 1024 * 1024,
    );
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('AudioStreamCacheManager generates deterministic cache files and checks status', () async {
    final file = await cacheManager.getCacheFile('test_song_123');
    expect(file.path, contains(tempDir.path));
    expect(file.path.endsWith('.cache'), isTrue);

    expect(await cacheManager.isTrackCached('test_song_123'), isFalse);
    await file.writeAsBytes(List.generate(100, (i) => i));
    expect(await cacheManager.isTrackCached('test_song_123'), isTrue);
  });

  test('AudioStreamCacheManager prunes oldest files on limit exceeded', () async {
    final file1 = await cacheManager.getCacheFile('song1');
    final file2 = await cacheManager.getCacheFile('song2');
    final file3 = await cacheManager.getCacheFile('song3');

    await file1.writeAsBytes(List.filled(400, 1));
    await file1.setLastModified(DateTime.now().subtract(const Duration(hours: 3)));

    await file2.writeAsBytes(List.filled(400, 2));
    await file2.setLastModified(DateTime.now().subtract(const Duration(hours: 2)));

    await file3.writeAsBytes(List.filled(400, 3));
    await file3.setLastModified(DateTime.now().subtract(const Duration(hours: 1)));

    // Total size = 1200 bytes, limit = 1024 bytes -> prunes oldest down to ~85%
    await cacheManager.pruneCacheIfNeeded(limitBytes: 1024);

    expect(await file1.exists(), isFalse, reason: 'Oldest file should be pruned');
    expect(await file3.exists(), isTrue, reason: 'Newest file should be kept');
  });

  test('AudioStreamCacheProxy starts, proxies HTTP stream, and caches automatically', () async {
    // 1. Mock upstream server
    final mockUpstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final mockBytes = List.generate(2048, (i) => i % 256);

    mockUpstream.listen((request) {
      if (request.uri.path == '/audio.mp3') {
        request.response.headers.contentType = ContentType('audio', 'mpeg');
        request.response.headers.contentLength = mockBytes.length;
        request.response.add(mockBytes);
        request.response.close();
      } else {
        request.response.statusCode = HttpStatus.notFound;
        request.response.close();
      }
    });

    final proxy = AudioStreamCacheProxy(cacheManager: cacheManager);
    final port = await proxy.start();
    expect(port, greaterThan(0));
    expect(proxy.isRunning, isTrue);

    final remoteUrl = 'http://127.0.0.1:${mockUpstream.port}/audio.mp3';
    final proxyUrl = proxy.buildProxyUrl(
      remoteUrl: remoteUrl,
      cacheKey: 'mock_track_1',
    );

    expect(proxyUrl, contains('127.0.0.1:$port/stream'));

    // 2. Client request to proxy
    final client = HttpClient();
    final req = await client.getUrl(Uri.parse(proxyUrl));
    final resp = await req.close();

    expect(resp.statusCode, HttpStatus.ok);
    final receivedBytes = <int>[];
    await for (final chunk in resp) {
      receivedBytes.addAll(chunk);
    }
    expect(receivedBytes.length, equals(mockBytes.length));
    expect(receivedBytes, equals(mockBytes));

    // 3. Verify that the track is fully cached on disk (awaiting the prefetch task)
    await proxy.ensureBackgroundPrefetch(
      targetUrl: remoteUrl,
      cacheKey: 'mock_track_1',
    );
    expect(await cacheManager.isTrackCached('mock_track_1'), isTrue);

    // 4. Second request should now serve directly from cache with partial range support
    final cachedReq = await client.getUrl(Uri.parse(proxyUrl));
    cachedReq.headers.set(HttpHeaders.rangeHeader, 'bytes=100-199');
    final cachedResp = await cachedReq.close();

    expect(cachedResp.statusCode, HttpStatus.partialContent);
    expect(cachedResp.headers.value(HttpHeaders.contentRangeHeader), equals('bytes 100-199/2048'));
    final rangeBytes = <int>[];
    await for (final chunk in cachedResp) {
      rangeBytes.addAll(chunk);
    }
    expect(rangeBytes.length, equals(100));
    expect(rangeBytes, equals(mockBytes.sublist(100, 200)));

    client.close();
    await proxy.stop();
    await mockUpstream.close(force: true);
  });

  test('AudioStreamCacheProxy correctly encodes and proxies upstream URLs with spaces, brackets and Unicode', () async {
    final mockUpstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final mockBytes = List.generate(1024, (i) => (i * 7) % 256);

    mockUpstream.listen((request) {
      // The decoded path matches the special character track
      if (Uri.decodeFull(request.uri.path) == '/music/(1) [] 君が好きだと叫びたい.flac') {
        final range = request.headers.value(HttpHeaders.rangeHeader);
        if (range != null && range.startsWith('bytes=')) {
          final rangeStr = range.substring(6);
          final parts = rangeStr.split('-');
          final start = int.parse(parts[0]);
          final end = parts.length > 1 && parts[1].isNotEmpty
              ? int.parse(parts[1])
              : mockBytes.length - 1;

          final sub = mockBytes.sublist(start, end + 1);
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-$end/${mockBytes.length}',
          );
          request.response.headers.contentLength = sub.length;
          request.response.add(sub);
          request.response.close();
        } else {
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentLength = mockBytes.length;
          request.response.add(mockBytes);
          request.response.close();
        }
      } else {
        request.response.statusCode = HttpStatus.notFound;
        request.response.close();
      }
    });

    final proxy = AudioStreamCacheProxy(cacheManager: cacheManager);
    final port = await proxy.start();

    final unencodedRemoteUrl = 'http://127.0.0.1:${mockUpstream.port}/music/(1) [] 君が好きだと叫びたい.flac';
    final proxyUrl = proxy.buildProxyUrl(
      remoteUrl: unencodedRemoteUrl,
      cacheKey: 'special_char_track',
    );

    final client = HttpClient();

    // 1. Seek / Range request without full cache
    final req = await client.getUrl(Uri.parse(proxyUrl));
    req.headers.set(HttpHeaders.rangeHeader, 'bytes=500-799');
    final resp = await req.close();

    expect(resp.statusCode, HttpStatus.partialContent);
    final received = <int>[];
    await for (final chunk in resp) {
      received.addAll(chunk);
    }
    expect(received.length, equals(300));
    expect(received, equals(mockBytes.sublist(500, 800)));

    client.close();
    await proxy.stop();
    await mockUpstream.close(force: true);
  });
}
