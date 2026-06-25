import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';
import 'package:audio_core/src/audio_engine/audio_engine_interface.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AudioCoreController instances do not share state', () async {
    final controllerA = AudioCoreController(
      fftSize: 256,
      engine: FakeAudioEngine(),
    );
    final controllerB = AudioCoreController(
      fftSize: 512,
      engine: FakeAudioEngine(),
    );

    addTearDown(controllerA.dispose);
    addTearDown(controllerB.dispose);

    expect(identical(controllerA, controllerB), isFalse);
    expect(controllerA.fftSize, 256);
    expect(controllerB.fftSize, 512);

    controllerA.player.setFadeSettings(const FadeSettings(fadeOnSwitch: true));

    expect(controllerA.player.fadeSettings.fadeOnSwitch, isTrue);
    expect(controllerB.player.fadeSettings.fadeOnSwitch, isFalse);
  });
}

final class FakeAudioEngine implements AudioEngine {
  @override
  bool get fftDataIsPreGrouped => false;

  @override
  bool get supportsCrossfade => false;

  @override
  Stream<AudioStatus> get statusStream => const Stream<AudioStatus>.empty();

  @override
  Future<void> initialize() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}

  @override
  Future<void> load(String path) async {}

  @override
  Future<void> crossfade(
    String path,
    Duration duration, {
    Duration? position,
  }) async {}

  @override
  Future<void> transition(
    String path,
    Duration duration, {
    Duration? position,
    required bool autoPlay,
    double? targetVolume,
  }) async {}

  @override
  Future<void> play({Duration? fadeDuration}) async {}

  @override
  Future<void> pause({Duration? fadeDuration}) async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<Duration> getDuration() async => const Duration(minutes: 3);

  @override
  Future<PositionSnapshot> getCurrentPosition() async {
    return PositionSnapshot(
      position: Duration.zero,
      takenAtMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  @override
  Future<List<double>> getLatestFft() async => const <double>[];

  @override
  Future<void> updateVisualizerFftOptions(
    VisualizerOptimizationOptions options,
  ) async {}

  @override
  Future<Float32List> getAudioPcm({String? path, int sampleStride = 0}) async {
    return Float32List(0);
  }

  @override
  Future<int> getAudioPcmChannelCount({String? path}) async => 1;

  @override
  Future<List<double>> getWaveform({
    required String path,
    required int expectedChunks,
    int sampleStride = 0,
  }) async {
    return const <double>[];
  }

  @override
  Future<void> setEqualizerConfig(EqualizerConfig config) async {}

  @override
  Future<EqualizerConfig> getEqualizerConfig() async {
    return EqualizerConfig(
      enabled: false,
      bandCount: 0,
      preampDb: 0.0,
      bassBoostDb: 0.0,
      bassBoostFrequencyHz: 0.0,
      bassBoostQ: 1.0,
      bandGainsDb: Float32List(0),
    );
  }

  @override
  Future<String?> extractFingerprint(String path) async => null;

  @override
  Future<void> prepareForFileWrite() async {}

  @override
  Future<void> finishFileWrite() async {}

  @override
  Future<bool> registerPersistentAccess(String path) async => false;

  @override
  Future<void> forgetPersistentAccess(String path) async {}

  @override
  Future<bool> hasPersistentAccess(String path) async => false;

  @override
  Future<List<String>> listPersistentAccessPaths() async => const <String>[];

  @override
  Future<bool> beginScopedAccess(String path) async => false;

  @override
  Future<void> endScopedAccess(String path) async {}

  @override
  Future<GeneratedTrackArtwork> generateTrackArtwork({
    required String path,
    Uint8List? artworkBytes,
    required String cacheRootPath,
    required bool saveLargeArtwork,
    TrackArtworkOptions options = const TrackArtworkOptions(),
  }) async {
    return const GeneratedTrackArtwork(artworkFound: false);
  }

  @override
  Future<String> getDecodeEngine() async => 'fake';
}
