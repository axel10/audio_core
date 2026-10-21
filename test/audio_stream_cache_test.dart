import 'dart:async';
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
      // Generous default: individual tests that need a tight budget pass
      // `limitBytes` explicitly.
      maxCacheSizeBytesGetter: () => 64 * 1024 * 1024,
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
    await proxy.start();

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

  group('stream write-back', () {
    test('completes into the cache file when every declared byte arrived', () async {
      final writer = await cacheManager.beginStreamWrite(
        cacheKey: 'full_track',
        expectedTotal: 8,
      );
      expect(writer, isNotNull);

      writer!.addChunk([1, 2, 3, 4]);
      writer.addChunk([5, 6, 7, 8]);
      expect(writer.written, 8);

      final cached = await writer.complete();
      expect(cached, isNotNull);
      expect(await cacheManager.isTrackCached('full_track'), isTrue);
      expect(await cached!.readAsBytes(), equals([1, 2, 3, 4, 5, 6, 7, 8]));
    });

    test('discards the .part file when the byte count falls short', () async {
      final writer = await cacheManager.beginStreamWrite(
        cacheKey: 'short_track',
        expectedTotal: 100,
      );
      expect(writer, isNotNull);

      writer!.addChunk(List<int>.filled(40, 7));
      final cached = await writer.complete();

      expect(cached, isNull, reason: 'a partial body must never be cached');
      expect(await cacheManager.isTrackCached('short_track'), isFalse);
      final leftovers = tempDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.part'))
          .toList();
      expect(leftovers, isEmpty);
    });

    test('allows only one writer per cache key at a time', () async {
      final first = await cacheManager.beginStreamWrite(
        cacheKey: 'dup_track',
        expectedTotal: 4,
      );
      expect(first, isNotNull);
      expect(cacheManager.isWriteInProgress('dup_track'), isTrue);

      final second = await cacheManager.beginStreamWrite(
        cacheKey: 'dup_track',
        expectedTotal: 4,
      );
      expect(second, isNull, reason: 'second writer must not open a .part file');

      await first!.abort();
      expect(cacheManager.isWriteInProgress('dup_track'), isFalse);
      expect(await cacheManager.isTrackCached('dup_track'), isFalse);
    });

    test('ensureTrackCached waits for the in-flight write-back instead of downloading', () async {
      final writer = await cacheManager.beginStreamWrite(
        cacheKey: 'wait_track',
        expectedTotal: 4,
      );
      expect(writer, isNotNull);

      // An unreachable URL: if the manager opened a second connection this
      // future would fail instead of resolving to the mirrored bytes.
      final pending = cacheManager.ensureTrackCached(
        cacheKey: 'wait_track',
        remoteUrl: 'http://127.0.0.1:1/unreachable.flac',
      );

      writer!.addChunk([9, 8, 7, 6]);
      await writer.complete();

      final file = await pending;
      expect(await file.readAsBytes(), equals([9, 8, 7, 6]));
    });

    test('playback caches the track without a second upstream request', () async {
      final mockBytes = List<int>.generate(64 * 1024, (i) => i % 256);
      var upstreamRequests = 0;

      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstream.listen((request) {
        upstreamRequests++;
        request.response.headers.contentType = ContentType('audio', 'flac');
        request.response.headers.contentLength = mockBytes.length;
        request.response.add(mockBytes);
        request.response.close();
      });

      final cachedCompleter = Completer<File>();
      cacheManager.onTrackCached = (key, file) {
        if (key == 'tee_track' && !cachedCompleter.isCompleted) {
          cachedCompleter.complete(file);
        }
      };

      final proxy = AudioStreamCacheProxy(cacheManager: cacheManager);
      await proxy.start();
      final client = HttpClient();
      final url = proxy.buildProxyUrl(
        remoteUrl: 'http://127.0.0.1:${upstream.port}/tee.flac',
        cacheKey: 'tee_track',
      );

      final resp = await (await client.getUrl(Uri.parse(url))).close();
      final received = <int>[];
      await for (final chunk in resp) {
        received.addAll(chunk);
      }
      expect(received, equals(mockBytes));

      final cached =
          await cachedCompleter.future.timeout(const Duration(seconds: 10));
      expect(await cached.length(), mockBytes.length);
      expect(await cached.readAsBytes(), equals(mockBytes));

      expect(
        upstreamRequests,
        1,
        reason: 'the forwarded bytes are the cached bytes; nothing is fetched twice',
      );

      client.close();
      await proxy.stop();
      await upstream.close(force: true);
    });

    test('falls back to a second request when the upstream length is unknown', () async {
      final mockBytes = List<int>.generate(32 * 1024, (i) => i % 256);
      var upstreamRequests = 0;

      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstream.listen((request) {
        upstreamRequests++;
        // No contentLength -> chunked body, no total to mirror against.
        request.response.headers.contentType = ContentType('audio', 'flac');
        request.response.add(mockBytes);
        request.response.close();
      });

      final cachedCompleter = Completer<File>();
      cacheManager.onTrackCached = (key, file) {
        if (key == 'chunked_track' && !cachedCompleter.isCompleted) {
          cachedCompleter.complete(file);
        }
      };

      final proxy = AudioStreamCacheProxy(cacheManager: cacheManager);
      await proxy.start();
      final client = HttpClient();
      final url = proxy.buildProxyUrl(
        remoteUrl: 'http://127.0.0.1:${upstream.port}/chunked.flac',
        cacheKey: 'chunked_track',
      );

      final resp = await (await client.getUrl(Uri.parse(url))).close();
      final received = <int>[];
      await for (final chunk in resp) {
        received.addAll(chunk);
      }
      expect(received, equals(mockBytes));

      final cached =
          await cachedCompleter.future.timeout(const Duration(seconds: 10));
      expect(await cached.readAsBytes(), equals(mockBytes));
      expect(
        upstreamRequests,
        2,
        reason: 'unknown length keeps the legacy pass-through + prefetch path',
      );

      client.close();
      await proxy.stop();
      await upstream.close(force: true);
    });
  });
}
