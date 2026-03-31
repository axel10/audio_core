import 'dart:async';
import '../rust/api/simple/equalizer.dart';
import '../player_models.dart';

/// Define a unified status update for all platforms.
class AudioStatus {
  final String? path;
  final Duration position;
  final Duration duration;
  final bool isPlaying;
  final double volume;
  final String? error;

  AudioStatus({
    this.path,
    required this.position,
    required this.duration,
    required this.isPlaying,
    required this.volume,
    this.error,
  });
}

abstract class AudioEngine {
  Future<void> initialize();
  Future<void> dispose();

  Future<void> load(String path);
  Future<void> crossfade(String path, Duration duration);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setVolume(double volume);

  Future<Duration> getDuration();
  Future<Duration> getCurrentPosition();

  // Visualization
  Future<List<double>> getLatestFft();
  Future<List<double>> getWaveform({
    required String path,
    required int expectedChunks,
    int sampleStride = 1,
  });

  // Effects
  Future<void> setEqualizerConfig(EqualizerConfig config);
  Future<EqualizerConfig> getEqualizerConfig();

  // Platform specific features (optional or capabilities-based)
  bool get supportsCrossfade;
  Future<void> setFadeSettings(FadeSettings settings);

  // Status updates
  Stream<AudioStatus> get statusStream;
}
