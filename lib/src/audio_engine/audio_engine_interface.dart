import 'dart:async';
import 'dart:typed_data';
import '../fft_processor.dart';
import '../rust/api/simple/equalizer.dart';
import '../track_metadata.dart';

/// Define a unified status update for all platforms.
class AudioStatus {
  final String? path;
  final String? playbackState;
  final Duration position;
  final Duration duration;
  final bool isPlaying;
  final double volume;
  final String? error;

  AudioStatus({
    this.path,
    this.playbackState,
    required this.position,
    required this.duration,
    required this.isPlaying,
    required this.volume,
    this.error,
  });
}

abstract class AudioEngine {
  Future<void> initialize();
  Future<void> stop();
  Future<void> dispose();

  Future<void> load(String path);
  Future<void> crossfade(String path, Duration duration, {Duration? position});
  Future<void> play({Duration? fadeDuration});
  Future<void> pause({Duration? fadeDuration});
  Future<void> seek(Duration position);
  Future<void> setVolume(double volume);

  Future<Duration> getDuration();
  Future<Duration> getCurrentPosition();

  // Visualization
  Future<List<double>> getLatestFft();
  Future<void> updateVisualizerFftOptions(
    VisualizerOptimizationOptions options,
  );
  bool get fftDataIsPreGrouped;
  Future<Float32List> getAudioPcm({String? path, int sampleStride});

  Future<int> getAudioPcmChannelCount({String? path});
  Future<List<double>> getWaveform({
    required String path,
    required int expectedChunks,
    int sampleStride = 0,
  });

  // Effects
  Future<void> setEqualizerConfig(EqualizerConfig config);
  Future<EqualizerConfig> getEqualizerConfig();

  // Platform specific features (optional or capabilities-based)
  bool get supportsCrossfade;

  // Audio Fingerprinting
  Future<String?> extractFingerprint(String path);

  // Status updates
  Stream<AudioStatus> get statusStream;

  // File synchronization (locking)
  Future<void> prepareForFileWrite();
  Future<void> finishFileWrite();

  // Apple security-scoped access persistence
  Future<bool> registerPersistentAccess(String path);
  Future<void> forgetPersistentAccess(String path);
  Future<bool> hasPersistentAccess(String path);
  Future<List<String>> listPersistentAccessPaths();

  // Native metadata updates
  Future<bool> updateTrackMetadata({
    required String path,
    required Map<String, Object?> metadata,
  });

  Future<TrackMetadata> getTrackMetadata({
    required String path,
    String? fallbackMediaUri,
  }) async {
    throw UnimplementedError(
      'getTrackMetadata is not implemented on this platform.',
    );
  }

  Future<void> removeAllTags({String? path});
}
