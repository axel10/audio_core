import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:meta/meta.dart';
import 'package:my_exoplayer/my_exoplayer.dart';

import 'player_models.dart';
import 'rust/api/simple_api.dart' as rust_api;
import 'rust/api/simple/controller.dart' as rust_controller;

/// Manages the actual audio engine session and transitions.
class PlayerController extends ChangeNotifier {
  PlayerController({
    required AudioVisualizerParent parent,
  }) : _parent = parent;

  final AudioVisualizerParent _parent;

  String? _selectedPath;
  String? _error;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  bool _isPlaying = false;
  double _volume = 1.0;
  
  FadeSettings _fadeSettings = const FadeSettings();
  int _fadeSequence = 0;
  bool _trackFadeTransitionActive = false;
  PlayerState _playerState = PlayerState.idle;
  DateTime _lastCommandTime = DateTime.fromMillisecondsSinceEpoch(0);

  // --- Getters ---
  String? get currentPath => _selectedPath;
  String? get error => _error;
  Duration get duration => _duration;
  Duration get position => _position;
  bool get isPlaying => _isPlaying;
  double get volume => _volume;
  PlayerState get currentState => _playerState;
  FadeSettings get fadeSettings => _fadeSettings;
  bool get isFadeActive => _trackFadeTransitionActive;
  int get fadeSequence => _fadeSequence;

  @internal
  void nextFadeSequence() => _fadeSequence++;

  // --- Actions ---

  @internal
  Future<void> performTransition({
    required String uri,
    required bool autoPlay,
    Duration? position,
    required void Function(bool progressing) onStateChanged,
  }) async {
    final switchingTracks = _selectedPath != null && _selectedPath != uri;
    
    PlaybackTransition strategy = const ImmediateTransition();

    if (switchingTracks && _fadeSettings.fadeOnSwitch && _fadeSettings.duration > Duration.zero) {
      if (_fadeSettings.mode == FadeMode.crossfade && isPlaying && autoPlay && position == null && !Platform.isAndroid) {
        strategy = CrossfadeTransition(duration: _fadeSettings.duration);
      } else {
        strategy = SequentialFadeTransition(
          duration: _fadeSettings.duration,
          targetVolume: _volume,
        );
      }
    }

    onStateChanged(true);
    try {
      await strategy.execute(
        player: this,
        uri: uri,
        autoPlay: autoPlay,
        position: position,
      );
    } finally {
      onStateChanged(false);
    }
  }

  Future<void> load(String path, {double? nativeVolume}) async {
    _error = null;
    if (path.isEmpty) {
      setError('Selected file path is unavailable.');
      return;
    }

    _playerState = PlayerState.buffering;
    notifyListeners();

    try {
      if (Platform.isAndroid) {
        await MyExoplayer.load(path);
        await MyExoplayer.setVolume(nativeVolume ?? _volume);
        final durationMs = await MyExoplayer.getDuration();
        _selectedPath = path;
        _position = Duration.zero;
        _duration = Duration(milliseconds: durationMs);
        _lastCommandTime = DateTime.now();
        _isPlaying = false;
        _playerState = PlayerState.ready;
      } else {
        await rust_api.loadAudioFile(path: path);
        await applyNativeVolume(nativeVolume ?? _volume);
        final durationMs = await rust_api.getAudioDurationMs();
        _selectedPath = path;
        _position = Duration.zero;
        _duration = Duration(milliseconds: durationMs.toInt());
        _lastCommandTime = DateTime.now();
        _isPlaying = false;
        _playerState = PlayerState.ready;
      }
    } catch (e) {
      setError('Load failed: $e');
    }
    notifyListeners();
  }

  Future<void> togglePlayPause() async {
    if (_selectedPath == null) return;
    if (_isPlaying) {
      await pause();
    } else {
      await play();
    }
  }

  Future<void> pause() async {
    try {
      if (Platform.isAndroid) {
        // AndroidAudioEngine implementation (if used) would handle this internally.
        // But here we are still calling MyExoplayer directly in PlayerController.
        // TODO: We should eventually migrate everything to use AudioEngine interface.
        if (_fadeSettings.fadeOnPauseResume) {
          await fadeNativeVolume(from: _volume, to: 0.0, duration: _fadeSettings.duration, sequence: _fadeSequence);
          await MyExoplayer.pause();
          await applyNativeVolume(_volume); // Restore volume for next play
        } else {
          await MyExoplayer.pause();
        }
      } else {
        // Rust handles fade internally if configured
        await rust_api.pauseAudio();
      }
      _lastCommandTime = DateTime.now();
      _isPlaying = false;
      _playerState = PlayerState.paused;
    } catch (e) {
      setError('Pause failed: $e');
    }
    notifyListeners();
  }

  Future<void> play() async {
    if (_selectedPath == null) return;

    if (_playerState == PlayerState.completed) {
      final handled = await _parent.handlePlayRequested();
      if (handled) return;
    }

    try {
      if (_playerState == PlayerState.completed) {
        await seek(Duration.zero);
      }
      
      if (Platform.isAndroid) {
        if (_fadeSettings.fadeOnPauseResume) {
          await applyNativeVolume(0.0);
          await MyExoplayer.play();
          await fadeNativeVolume(from: 0.0, to: _volume, duration: _fadeSettings.duration, sequence: _fadeSequence, followTargetVolume: true);
        } else {
          await MyExoplayer.play();
        }
      } else {
        // Rust handles fade internally if configured
        await rust_api.playAudio();
      }
      _lastCommandTime = DateTime.now();
      _isPlaying = true;
      _playerState = PlayerState.playing;
    } catch (e) {
      setError('Play failed: $e');
    }
    notifyListeners();
  }

  Future<void> seek(Duration target) async {
    if (_selectedPath == null) return;
    final ms = target.inMilliseconds.clamp(0, _duration.inMilliseconds);
    try {
      if (Platform.isAndroid) {
        await MyExoplayer.seek(ms);
      } else {
        await rust_api.seekAudioMs(positionMs: ms.toInt());
      }
      _lastCommandTime = DateTime.now();
      _position = Duration(milliseconds: ms);
    } catch (e) {
      setError('Seek failed: $e');
    }
    notifyListeners();
  }

  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0);
    if (!_trackFadeTransitionActive) {
      await applyNativeVolume(_volume);
    }
    notifyListeners();
  }

  void setFadeSettings(FadeSettings settings) {
    _fadeSettings = settings;
    if (!Platform.isAndroid) {
      // Sync to Rust
      rust_api.setAudioFadeSettings(
        settings: rust_controller.FadeSettings(
          fadeOnSwitch: settings.fadeOnSwitch,
          fadeOnPauseResume: settings.fadeOnPauseResume,
          durationMs: settings.duration.inMilliseconds.toInt(),
          mode: settings.mode == FadeMode.crossfade ? rust_controller.FadeMode.crossfade : rust_controller.FadeMode.sequential,
        ),
      );
    }
    notifyListeners();
  }

  @internal
  Future<void> applyNativeVolume(double volume) async {
    final clamped = volume.clamp(0.0, 1.0);
    if (Platform.isAndroid) {
      await MyExoplayer.setVolume(clamped);
    } else {
      await rust_api.setAudioVolume(volume: clamped);
    }
  }

  Future<bool> fadeNativeVolume({
    required double from,
    required double to,
    required Duration duration,
    required int sequence,
    bool followTargetVolume = false,
  }) async {
    if (duration <= Duration.zero) {
      if (_fadeSequence != sequence) return false;
      await applyNativeVolume(followTargetVolume ? _volume : to);
      return _fadeSequence == sequence;
    }

    final steps = (duration.inMilliseconds / 16).round().clamp(1, 1000);
    final stepDelay = Duration(microseconds: (duration.inMicroseconds / steps).round());

    for (var i = 1; i <= steps; i++) {
      if (_fadeSequence != sequence) return false;
      final progress = i / steps;
      final endVolume = followTargetVolume ? _volume : to;
      final nextVolume = from + ((endVolume - from) * progress);
      await applyNativeVolume(nextVolume);
      if (i < steps) {
        await Future<void>.delayed(stepDelay);
      }
    }
    return _fadeSequence == sequence;
  }

  @internal
  void setFadeActive(bool active) {
    _trackFadeTransitionActive = active;
    notifyListeners();
  }

  Future<void> stopPlayback() async {
    _selectedPath = null;
    _position = Duration.zero;
    _duration = Duration.zero;
    _isPlaying = false;
    _playerState = PlayerState.idle;
    notifyListeners();
  }

  // --- External Sync Interface ---

  @internal
  void applySnapshot(String? path, Duration position, Duration duration, bool isPlaying, double nativeVolume) {
    final now = DateTime.now();
    final recentlyCommanded = now.difference(_lastCommandTime) < const Duration(milliseconds: 500);

    // Update duration and volume even if recently commanded
    if (duration > Duration.zero) {
      _duration = duration;
    }
    
    if (!_trackFadeTransitionActive) {
      _volume = nativeVolume;
    }

    // Guard position and playing state to avoid "jumping" back to old state during command processing
    if (recentlyCommanded) {
       notifyListeners();
       return;
    }

    _selectedPath = path;
    _position = position;
    _isPlaying = isPlaying;
    
    if (_isPlaying) {
      _playerState = PlayerState.playing;
    } else if (_selectedPath != null && _duration > Duration.zero && _position.inMilliseconds >= (_duration.inMilliseconds - 250)) {
       _playerState = PlayerState.completed;
    } else if (_selectedPath != null) {
      _playerState = PlayerState.paused;
    }
    
    notifyListeners();
  }

  @internal
  void setError(String? message) {
    _error = message;
    if (message != null) _playerState = PlayerState.error;
    notifyListeners();
  }

  @internal
  void updatePosition(Duration position) {
    if (DateTime.now().difference(_lastCommandTime) < const Duration(milliseconds: 500)) return;

    _position = position;
    if (_duration > Duration.zero && _position >= _duration - const Duration(milliseconds: 250)) {
      _isPlaying = false;
      _playerState = PlayerState.completed;
    }
    notifyListeners();
  }

  @internal
  void updateDuration(Duration duration) {
    _duration = duration;
    notifyListeners();
  }

  @override
  void notifyListeners() {
    super.notifyListeners();
    _parent.notifyListeners();
  }
}

/// Defines the strategy for transitioning between two audio tracks.
abstract class PlaybackTransition {
  const PlaybackTransition();
  Future<void> execute({
    required PlayerController player,
    required String uri,
    required bool autoPlay,
    Duration? position,
  });
}

class SequentialFadeTransition extends PlaybackTransition {
  const SequentialFadeTransition({required this.duration, required this.targetVolume});
  final Duration duration;
  final double targetVolume;

  @override
  Future<void> execute({required PlayerController player, required String uri, required bool autoPlay, Duration? position}) async {
    player.nextFadeSequence();
    final seq = player.fadeSequence;

    if (player.isPlaying) {
      player.setFadeActive(true);
      try {
        final fadedOut = await player.fadeNativeVolume(from: player.volume, to: 0.0, duration: duration, sequence: seq);
        if (!fadedOut) return;
      } finally {
        if (!autoPlay) player.setFadeActive(false);
      }
    }

    await player.load(uri, nativeVolume: autoPlay ? 0.0 : player.volume);
    if (player.fadeSequence != seq) return;
    if (position != null) await player.seek(position);

    if (autoPlay) {
      player.setFadeActive(true);
      try {
        await player.play();
        await player.fadeNativeVolume(from: 0.0, to: targetVolume, duration: duration, sequence: seq, followTargetVolume: true);
      } finally {
        player.setFadeActive(false);
      }
    }
  }
}

class CrossfadeTransition extends PlaybackTransition {
  const CrossfadeTransition({required this.duration});
  final Duration duration;

  @override
  Future<void> execute({required PlayerController player, required String uri, required bool autoPlay, Duration? position}) async {
    player.nextFadeSequence();
    final seq = player.fadeSequence;
    await rust_api.crossfadeToAudioFile(path: uri, durationMs: duration.inMilliseconds.toInt());
    if (player.fadeSequence != seq) return;
    final durationMs = await rust_api.getAudioDurationMs();
    player.applySnapshot(uri, Duration.zero, Duration(milliseconds: durationMs.toInt()), true, player.volume);
  }
}

class ImmediateTransition extends PlaybackTransition {
  const ImmediateTransition();
  @override
  Future<void> execute({required PlayerController player, required String uri, required bool autoPlay, Duration? position}) async {
    player.nextFadeSequence();
    await player.load(uri);
    if (position != null) await player.seek(position);
    if (autoPlay) await player.play();
  }
}
