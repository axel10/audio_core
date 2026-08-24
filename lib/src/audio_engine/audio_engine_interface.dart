import 'dart:async';
import 'dart:typed_data';
import '../fft_processor.dart';
import '../track_artwork.dart';
import '../rust/api/simple/equalizer.dart';
import '../rust/api/simple_api.dart' as rust;
import '../track_metadata.dart';
import '../track_metadata_update.dart';
import '../audio_details.dart';

/// Define a snapshot for highly accurate position synchronization.
class PositionSnapshot {
  final Duration position;
  final int takenAtMs;

  PositionSnapshot({required this.position, required this.takenAtMs});
}

/// Define a unified status update for all platforms.
class AudioStatus {
  final String? path;
  final String? playbackState;
  final Duration position;
  final Duration duration;
  final bool isPlaying;
  final double volume;
  final String? error;
  final int? updateTimeSinceEpochMs;

  AudioStatus({
    this.path,
    this.playbackState,
    required this.position,
    required this.duration,
    required this.isPlaying,
    required this.volume,
    this.updateTimeSinceEpochMs,
    this.error,
  });
}

abstract class AudioEngine {
  Future<void> initialize();
  Future<void> stop();
  Future<void> dispose();

  Future<void> load(String path);
  Future<void> crossfade(String path, Duration duration, {Duration? position});
  Future<void> transition(
    String path,
    Duration duration, {
    Duration? position,
    required bool autoPlay,
    double? targetVolume,
  }) async {
    throw UnimplementedError('transition is not implemented on this platform.');
  }

  Future<void> play({Duration? fadeDuration});
  Future<void> pause({Duration? fadeDuration});
  Future<void> seek(Duration position);
  Future<void> setVolume(double volume);
  Future<void> setPlaybackSpeed(double speed);
  Future<double> getPlaybackSpeed();

  Future<Duration> getDuration();
  Future<PositionSnapshot> getCurrentPosition();

  // Visualization
  Future<List<double>> getLatestFft();
  Future<void> updateVisualizerFftOptions(
    VisualizerOptimizationOptions options,
  );
  Future<void> setFftCaptureEnabled(bool enabled) async {}
  bool get fftDataIsPreGrouped;
  Future<Float32List> getAudioPcm({String? path, int sampleStride});

  Future<int> getAudioPcmChannelCount({String? path});
  Future<List<double>> getWaveform({
    required String path,
    required int expectedChunks,
    int sampleStride = 0,
  });

  Stream<List<double>> streamWaveform({
    required String path,
    required int expectedChunks,
    int sampleStride = 0,
  }) async* {
    final waveform = await getWaveform(
      path: path,
      expectedChunks: expectedChunks,
      sampleStride: sampleStride,
    );
    if (waveform.isNotEmpty) {
      yield waveform;
    }
  }

  // Effects
  Future<void> setEqualizerConfig(EqualizerConfig config);
  Future<EqualizerConfig> getEqualizerConfig();

  // Platform specific features (optional or capabilities-based)
  bool get supportsCrossfade;

  // Audio Fingerprinting
  Future<String?> extractFingerprint(String path);

  // Status updates
  Stream<AudioStatus> get statusStream;

  Future<String> getDecodeEngine();

  // File synchronization (locking)
  Future<void> prepareForFileWrite();
  Future<void> finishFileWrite();

  // Apple security-scoped access persistence
  Future<bool> registerPersistentAccess(String path);
  Future<void> forgetPersistentAccess(String path);
  Future<bool> hasPersistentAccess(String path);
  Future<List<String>> listPersistentAccessPaths();
  Future<bool> beginScopedAccess(String path);
  Future<void> endScopedAccess(String path);

  // Native metadata updates
  Future<bool> updateTrackMetadata({
    required String path,
    required Map<String, Object?> metadata,
  });

  Future<List<bool>> updateTrackMetadataBatch({
    required List<TrackMetadataWriteRequest> requests,
  }) async {
    throw UnimplementedError(
      'updateTrackMetadataBatch is not implemented on this platform.',
    );
  }

  Future<bool> supportsBatchMetadataWrite() async => true;

  Future<List<bool>> copyTrackMetadataBatch({
    required List<TrackMetadataCopyRequest> requests,
  }) async {
    throw UnimplementedError(
      'copyTrackMetadataBatch is not implemented on this platform.',
    );
  }

  Future<TrackMetadata> getTrackMetadata({
    required String path,
    String? fallbackMediaUri,
  }) async {
    throw UnimplementedError(
      'getTrackMetadata is not implemented on this platform.',
    );
  }

  Future<AudioDetails> getAudioDetails({
    required String path,
  }) async {
    throw UnimplementedError(
      'getAudioDetails is not implemented on this platform.',
    );
  }

  Future<GeneratedTrackArtwork> generateTrackArtwork({
    required String path,
    Uint8List? artworkBytes,
    required String cacheRootPath,
    required bool saveLargeArtwork,
    TrackArtworkOptions options = const TrackArtworkOptions(),
  }) async {
    throw UnimplementedError(
      'generateTrackArtwork is not implemented on this platform.',
    );
  }

  Future<void> removeAllTags({String? path});
}

Future<List<double>> loadWaveformFromRust({
  required String path,
  required int expectedChunks,
  int sampleStride = 0,
}) async {
  if (expectedChunks <= 0) return const <double>[];
  final waveform = await rust.getAudioWaveform(
    path: path,
    expectedChunks: BigInt.from(expectedChunks),
    sampleStride: BigInt.from(sampleStride),
  );
  return waveform.toList(growable: false);
}
