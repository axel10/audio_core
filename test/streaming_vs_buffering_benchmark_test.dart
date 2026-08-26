import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:audio_core/audio_core.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late AudioStreamCacheManager cacheManager;

  setUp(() async {
    HttpOverrides.global = null;
    tempDir = await Directory.systemTemp.createTemp('benchmark_cache_');
    cacheManager = AudioStreamCacheManager(
      customCacheDirectory: tempDir,
      maxCacheSizeBytesGetter: () => 50 * 1024 * 1024,
    );
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('Benchmark: Real Navidrome Streaming vs Full Buffering Playback Speed', () async {
    const serverUrl = 'https://demo.navidrome.org';
    const username = 'demo';
    const password = 'demo';
    const salt = 'vynody_benchmark_salt';
    final token = md5.convert(utf8.encode(password + salt)).toString();

    final client = HttpClient();

    // 1. Fetch a random song from Navidrome Demo Server
    final randomSongsUrl = '$serverUrl/rest/getRandomSongs?u=$username&t=$token&s=$salt&v=1.16.1&c=vibe_flow&f=json&size=1';
    final randomReq = await client.getUrl(Uri.parse(randomSongsUrl));
    final randomResp = await randomReq.close();
    final randomBody = await randomResp.transform(utf8.decoder).join();
    final jsonData = jsonDecode(randomBody) as Map<String, dynamic>;

    final songs = jsonData['subsonic-response']?['randomSongs']?['song'] as List?;
    if (songs == null || songs.isEmpty) {
      fail('Failed to fetch songs from demo.navidrome.org: $randomBody');
    }

    final song = songs.first as Map<String, dynamic>;
    final songId = song['id'].toString();
    final songTitle = song['title'] ?? 'Unknown';
    final songArtist = song['artist'] ?? 'Unknown';
    final songSize = (song['size'] as num?)?.toInt() ?? 0;
    final songSuffix = song['suffix'] ?? 'mp3';

    final upstreamStreamUrl = '$serverUrl/rest/stream?u=$username&t=$token&s=$salt&v=1.16.1&c=vibe_flow&id=$songId';

    print('\n===============================================================');
    print('  🎵 测试音源: $songTitle - $songArtist');
    print('  📦 文件大小: ${(songSize / (1024 * 1024)).toStringAsFixed(2)} MB ($songSuffix)');
    print('  🌐 目标服务器: $serverUrl (公网真实服务器)');
    print('===============================================================');

    // --- TEST 1: Full Buffering (全量下载完成后才允许起播) ---
    final swFull = Stopwatch()..start();
    final fullFile = File('${tempDir.path}/full_download.$songSuffix');
    final reqFull = await client.getUrl(Uri.parse(upstreamStreamUrl));
    final respFull = await reqFull.close();
    final sink = fullFile.openWrite();
    await respFull.pipe(sink);
    swFull.stop();
    final fullBufferDurationMs = swFull.elapsedMilliseconds;
    final fullDownloadedBytes = await fullFile.length();

    // --- TEST 2: Progressive Streaming (通过本地代理流式边下边播) ---
    final proxy = AudioStreamCacheProxy(cacheManager: cacheManager);
    await proxy.start();
    final proxyUrl = proxy.buildProxyUrl(
      remoteUrl: upstreamStreamUrl,
      cacheKey: 'navidrome_demo_$songId',
    );

    final swStream = Stopwatch()..start();
    final reqStream = await client.getUrl(Uri.parse(proxyUrl));
    final respStream = await reqStream.close();

    // 测量首包到达时间 (Time To First Byte / Header) 与首个可用音频块 (64 KB)
    final ttfbCompleter = Completer<int>();
    final firstAudioBlockCompleter = Completer<int>();
    int streamReceivedBytes = 0;

    final subscription = respStream.listen((chunk) {
      if (!ttfbCompleter.isCompleted) {
        ttfbCompleter.complete(swStream.elapsedMilliseconds);
      }
      streamReceivedBytes += chunk.length;
      if (!firstAudioBlockCompleter.isCompleted && streamReceivedBytes >= 64 * 1024) {
        firstAudioBlockCompleter.complete(swStream.elapsedMilliseconds);
      }
    });

    final ttfbMs = await ttfbCompleter.future;
    final firstChunkMs = await firstAudioBlockCompleter.future;

    // 等待后台整首音频下载落盘完成
    await subscription.asFuture();
    swStream.stop();
    final totalStreamMs = swStream.elapsedMilliseconds;

    client.close();
    await proxy.stop();

    final avgSpeedMBs = (fullDownloadedBytes / (1024 * 1024)) / (fullBufferDurationMs / 1000);

    print('\n===============================================================');
    print('  📊 真实公网 Navidrome 播放延迟测试结果');
    print('===============================================================');
    print('  🌐 真实公网连接建立 + TTFB 响应耗时: ${ttfbMs}ms');
    print('  ⏳ 方案一【全量下载等待才播放】起播等待耗时: ${fullBufferDurationMs}ms (${(fullBufferDurationMs / 1000).toStringAsFixed(2)}s)');
    print('  ⚡ 方案二【流式边下边播】      首帧起播等待耗时: ${firstChunkMs}ms (${(firstChunkMs / 1000).toStringAsFixed(2)}s)');
    print('  🚀 起播响应提速率:             ${(fullBufferDurationMs / firstChunkMs).toStringAsFixed(1)} 倍！');
    print('  📈 实际网络平均下行速度:       ${avgSpeedMBs.toStringAsFixed(2)} MB/s');
    print('  💾 边播边存后台总完成耗时:     ${totalStreamMs}ms');
    print('  ✅ 最终本地离线缓存状态:       ${await cacheManager.isTrackCached('navidrome_demo_$songId') ? "已缓存 (下次0ms秒播)" : "未缓存"}');
    print('===============================================================\n');

    expect(firstChunkMs, lessThan(fullBufferDurationMs),
        reason: '流式首帧起播必须明显快于全量下载完成');
  });
}

