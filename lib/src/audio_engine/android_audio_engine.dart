import 'dart:async';
import 'package:my_exoplayer/my_exoplayer.dart';
import '../rust/api/simple/equalizer.dart';
import '../player_models.dart';
import 'audio_engine_interface.dart';

class AndroidAudioEngine implements AudioEngine {
  final _statusController = StreamController<AudioStatus>.broadcast();
  String? _currentPath;
  double _currentVolume = 1.0;
  FadeSettings _fadeSettings = const FadeSettings();

  @override
  Stream<AudioStatus> get statusStream => _statusController.stream;

  @override
  Future<void> initialize() async {
    MyExoplayer.setPlayerStateListener((
        {required playerId,
        required state,
        required isPlaying,
        required durationMs,
        required positionMs}) {
      // Only report status for the active player (the one that is not being faded out)
      if (playerId == _activePlayerId) {
        _statusController.add(AudioStatus(
          path: _currentPath,
          position: Duration(milliseconds: positionMs),
          duration: Duration(milliseconds: durationMs),
          isPlaying: isPlaying,
          volume: _currentVolume,
        ));
      }
    });
  }

  String _activePlayerId = 'main';
  EqualizerConfig? _lastConfig;

  @override
  Future<void> dispose() async {
    await _statusController.close();
    await MyExoplayer.dispose(playerId: 'main');
    await MyExoplayer.dispose(playerId: 'crossfade');
  }

  @override
  Future<void> load(String path) async {
    _currentPath = path;
    await MyExoplayer.load(path, playerId: _activePlayerId);
  }

  @override
  Future<void> play() async {
    if (_fadeSettings.fadeOnPauseResume) {
      await MyExoplayer.play(
        playerId: _activePlayerId,
        fadeDurationMs: _fadeSettings.duration.inMilliseconds,
        targetVolume: _currentVolume,
      );
    } else {
      await MyExoplayer.play(playerId: _activePlayerId);
    }
  }

  @override
  Future<void> pause() async {
    if (_fadeSettings.fadeOnPauseResume) {
      await MyExoplayer.pause(
        playerId: _activePlayerId,
        fadeDurationMs: _fadeSettings.duration.inMilliseconds,
      );
    } else {
      await MyExoplayer.pause(playerId: _activePlayerId);
    }
  }

  @override
  Future<void> seek(Duration position) =>
      MyExoplayer.seek(position.inMilliseconds, playerId: _activePlayerId);

  @override
  Future<void> setVolume(double volume) {
    _currentVolume = volume;
    return MyExoplayer.setVolume(volume, playerId: _activePlayerId);
  }

  @override
  Future<Duration> getDuration() async {
    final ms = await MyExoplayer.getDuration(playerId: _activePlayerId);
    return Duration(milliseconds: ms);
  }

  @override
  Future<Duration> getCurrentPosition() async {
    final ms = await MyExoplayer.getCurrentPosition(playerId: _activePlayerId);
    return Duration(milliseconds: ms);
  }

  @override
  Future<List<double>> getLatestFft() => MyExoplayer.getLatestFft(playerId: _activePlayerId);

  @override
  Future<List<double>> getWaveform({
    required String path,
    required int expectedChunks,
    int sampleStride = 1,
  }) async {
    final rawData = await MyExoplayer.getWaveform(path);
    if (rawData.isEmpty) return const [];
    
    final List<double> result = [];
    for (int i = 0; i < expectedChunks; i++) {
      final int sourceIdx = (i * rawData.length / expectedChunks).floor();
      // Normalize to 0.0 - 1.0. Amplituda typically returns 0-100.
      result.add(rawData[sourceIdx] / 100.0);
    }
    return result;
  }

  @override
  Future<void> setEqualizerConfig(EqualizerConfig config) async {
    _lastConfig = config;
    await _applyConfigToPlayer(_activePlayerId, config);
  }

  Future<void> _applyConfigToPlayer(String playerId, EqualizerConfig config) async {
    await MyExoplayer.setCppEqualizerEnabled(config.enabled, playerId: playerId);
    await MyExoplayer.setCppEqualizerPreAmp(config.preampDb, playerId: playerId);
    await MyExoplayer.setCppEqualizerBandCount(config.bandCount, playerId: playerId);
    await MyExoplayer.setCppEqualizerConfig(
      bandGains: config.bandGainsDb.toList(),
      playerId: playerId,
    );
  }

  @override
  Future<EqualizerConfig> getEqualizerConfig() async {
    if (_lastConfig != null) return _lastConfig!;
    throw UnimplementedError('getEqualizerConfig not available on Android yet');
  }

  @override
  bool get supportsCrossfade => true;

  @override
  Future<void> setFadeSettings(FadeSettings settings) async {
    _fadeSettings = settings;
  }
}
