import 'dart:async';
import 'dart:io';

import 'package:audio_core/audio_core.dart';
import 'package:audio_core/src/audio_engine/audio_engine_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class MockAudioEngine implements AudioEngine {
  final StreamController<AudioStatus> _statusController =
      StreamController<AudioStatus>.broadcast();

  final List<String> loadedPaths = [];
  final List<String> registeredPaths = [];
  final List<String> scopedAccessPaths = [];
  final List<String> playLog = [];

  bool isPlaying = false;
  Duration currentDuration = const Duration(minutes: 3);

  @override
  Stream<AudioStatus> get statusStream => _statusController.stream;

  void emitStatus(AudioStatus status) {
    _statusController.add(status);
  }

  @override
  Future<void> initialize() async {}

  @override
  Future<void> load(String path) async {
    loadedPaths.add(path);
  }

  @override
  Future<void> play({Duration? fadeDuration}) async {
    isPlaying = true;
    playLog.add('play');
  }

  @override
  Future<void> pause({Duration? fadeDuration}) async {
    isPlaying = false;
    playLog.add('pause');
  }

  @override
  Future<void> stop() async {
    isPlaying = false;
  }

  @override
  Future<void> dispose() async {
    await _statusController.close();
  }

  @override
  Future<bool> registerPersistentAccess(String path) async {
    registeredPaths.add(path);
    return true;
  }

  @override
  Future<bool> beginScopedAccess(String path) async {
    scopedAccessPaths.add(path);
    return true;
  }

  @override
  Future<void> endScopedAccess(String path) async {
    scopedAccessPaths.remove(path);
  }

  @override
  Future<void> forgetPersistentAccess(String path) async {
    registeredPaths.remove(path);
  }

  @override
  Future<bool> hasPersistentAccess(String path) async {
    return registeredPaths.contains(path);
  }

  @override
  Future<List<String>> listPersistentAccessPaths() async => registeredPaths;

  @override
  Future<Duration> getDuration() async => currentDuration;

  @override
  Future<PositionSnapshot> getCurrentPosition() async => PositionSnapshot(
        position: Duration.zero,
        takenAtMs: DateTime.now().millisecondsSinceEpoch,
      );

  @override
  bool get fftDataIsPreGrouped => false;

  @override
  bool get supportsCrossfade => false;

  @override
  Future<void> crossfade(
    String path,
    Duration duration, {
    Duration? position,
  }) async {
    loadedPaths.add(path);
  }

  @override
  Future<void> transition(
    String path,
    Duration duration, {
    Duration? position,
    required bool autoPlay,
    double? targetVolume,
  }) async {
    loadedPaths.add(path);
    if (autoPlay) isPlaying = true;
  }

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<List<double>> getLatestFft() async => const <double>[];

  @override
  Future<void> updateVisualizerFftOptions(
    VisualizerOptimizationOptions options,
  ) async {}

  @override
  Future<void> setFftCaptureEnabled(bool enabled) async {}

  @override
  Future<void> prepareForFileWrite() async {}

  @override
  Future<void> finishFileWrite() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockAudioEngine mockEngine;
  late AudioCoreController controller;
  late Directory tempDir;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('continuous_playback_test');
    mockEngine = MockAudioEngine();
    controller = AudioCoreController.forTesting(engine: mockEngine);
    await controller.initialize();
  });

  tearDown(() {
    controller.dispose();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('连续播放3首歌：每首播完自动切到下一首，且每首均正确触发授权与加载', () async {
    final file1 = File(p.join(tempDir.path, '01_intro.m4a'))..createSync();
    final file2 = File(p.join(tempDir.path, '02_melody.m4a'))..createSync();
    final file3 = File(p.join(tempDir.path, '03_outro.m4a'))..createSync();

    final track1 = file1.path;
    final track2 = file2.path;
    final track3 = file3.path;

    // 1. 开始播放第 1 首歌
    await controller.playPaths(
      [track1, track2, track3],
      startIndex: 0,
      autoPlayFirst: true,
    );

    expect(controller.playlist.currentIndex, 0);
    expect(controller.playlist.currentTrack?.uri, track1);
    expect(mockEngine.loadedPaths.last, track1);

    // 2. 模拟第 1 首歌播放完毕，native backend 发送 ENDED 事件
    mockEngine.emitStatus(
      AudioStatus(
        path: track1,
        playbackState: 'ENDED',
        position: const Duration(minutes: 3),
        duration: const Duration(minutes: 3),
        isPlaying: false,
        volume: 1.0,
      ),
    );

    // 等待自动切歌异步处理完成
    await Future.delayed(const Duration(milliseconds: 100));

    // 验证已经自动切到了第 2 首
    expect(controller.playlist.currentIndex, 1);
    expect(controller.playlist.currentTrack?.uri, track2);
    expect(mockEngine.loadedPaths.last, track2);

    // 3. 模拟第 2 首歌播放完毕，native backend 发送 ENDED 事件
    mockEngine.emitStatus(
      AudioStatus(
        path: track2,
        playbackState: 'ENDED',
        position: const Duration(minutes: 3),
        duration: const Duration(minutes: 3),
        isPlaying: false,
        volume: 1.0,
      ),
    );

    await Future.delayed(const Duration(milliseconds: 100));

    // 验证已经自动切到了第 3 首
    expect(controller.playlist.currentIndex, 2);
    expect(controller.playlist.currentTrack?.uri, track3);
    expect(mockEngine.loadedPaths.last, track3);

    // 验证所有 3 首歌都进入过 loadedPaths，顺序严格对应连续播放
    expect(mockEngine.loadedPaths, [track1, track2, track3]);
  });

  test('单曲循环模式下播放完毕：正常重新加载当前曲目', () async {
    final file = File(p.join(tempDir.path, 'single_song.m4a'))..createSync();
    final track = file.path;

    await controller.playPaths([track], autoPlayFirst: true);
    controller.playlist.setMode(PlaylistMode.singleLoop);

    expect(controller.playlist.currentIndex, 0);
    expect(mockEngine.loadedPaths.length, 1);

    // 模拟播放完毕
    mockEngine.emitStatus(
      AudioStatus(
        path: track,
        playbackState: 'ENDED',
        position: const Duration(minutes: 4),
        duration: const Duration(minutes: 4),
        isPlaying: false,
        volume: 1.0,
      ),
    );

    await Future.delayed(const Duration(milliseconds: 100));

    // 依然是第 0 首，且被重新 load 了
    expect(controller.playlist.currentIndex, 0);
    expect(controller.playlist.currentTrack?.uri, track);
    expect(mockEngine.loadedPaths.length, 2);
    expect(mockEngine.loadedPaths[1], track);
  });

  test('循环队列模式下：最后一首播完自动回到第一首', () async {
    final file1 = File(p.join(tempDir.path, 'track1.mp3'))..createSync();
    final file2 = File(p.join(tempDir.path, 'track2.mp3'))..createSync();

    final track1 = file1.path;
    final track2 = file2.path;

    await controller.playPaths([track1, track2], startIndex: 1);
    controller.playlist.setMode(PlaylistMode.queueLoop);

    expect(controller.playlist.currentIndex, 1);

    // 模拟最后一首（track2）播完
    mockEngine.emitStatus(
      AudioStatus(
        path: track2,
        playbackState: 'ENDED',
        position: const Duration(minutes: 3),
        duration: const Duration(minutes: 3),
        isPlaying: false,
        volume: 1.0,
      ),
    );

    await Future.delayed(const Duration(milliseconds: 100));

    // 自动循环回到第 0 首（track1）
    expect(controller.playlist.currentIndex, 0);
    expect(controller.playlist.currentTrack?.uri, track1);
    expect(mockEngine.loadedPaths.last, track1);
  });

  test('循环队列模式下：单曲队列播完自动循环重播该首', () async {
    final file = File(p.join(tempDir.path, 'single_track.mp3'))..createSync();
    final track = file.path;

    await controller.playPaths([track], startIndex: 0);
    controller.playlist.setMode(PlaylistMode.queueLoop);

    expect(controller.playlist.currentIndex, 0);
    expect(mockEngine.loadedPaths.length, 1);

    // 模拟单曲播完
    mockEngine.emitStatus(
      AudioStatus(
        path: track,
        playbackState: 'ENDED',
        position: const Duration(minutes: 3),
        duration: const Duration(minutes: 3),
        isPlaying: false,
        volume: 1.0,
      ),
    );

    await Future.delayed(const Duration(milliseconds: 100));

    expect(controller.playlist.currentIndex, 0);
    expect(controller.playlist.currentTrack?.uri, track);
    expect(mockEngine.loadedPaths.length, 2);
    expect(mockEngine.loadedPaths.last, track);
  });
}
