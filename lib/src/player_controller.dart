import 'dart:async';
import 'package:flutter/foundation.dart';

import 'player_models.dart';
import 'playlist_models.dart';

/// Manages the actual audio engine session and transitions.
class PlayerController extends ChangeNotifier {
  PlayerController({required AudioVisualizerParent parent}) : _parent = parent;

  final AudioVisualizerParent _parent;

  String? _selectedPath;
  String? _error;
  Duration _duration = Duration.zero;
  bool _durationReady = false;
  Duration _position = Duration.zero;
  bool _isPlaying = false;
  double _volume = 1.0;
  String? _lastFingerprint;

  FadeSettings _fadeSettings = const FadeSettings();
  PlayerState _playerState = PlayerState.idle;
  DateTime _lastCommandTime = DateTime.fromMillisecondsSinceEpoch(0);

  // --- Getters ---
  String? get currentPath => _selectedPath;
  String? get error => _error;
  Duration get duration => _durationReady ? _duration : Duration.zero;
  Duration get position => _position;
  bool get isPlaying => _isPlaying;
  double get volume => _volume;
  String? get lastFingerprint => _lastFingerprint;
  PlayerState get currentState => _playerState;
  FadeSettings get fadeSettings => _fadeSettings;

  // --- Actions ---

  @internal
  Future<void> performTransition({
    required String uri,
    required bool autoPlay,
    Duration? position,
    required PlaybackReason reason,
    FadeSettings? fadeSetting,
    required void Function(bool progressing) onStateChanged,
  }) async {
    final effectiveFadeSettings = fadeSetting ?? _fadeSettings;
    final switchingTracks = _selectedPath != null && _selectedPath != uri;
    final isActivelyPlaying = _isPlaying && _playerState == PlayerState.playing;
    final shouldFade =
        switchingTracks &&
        effectiveFadeSettings.fadeOnSwitch &&
        effectiveFadeSettings.duration > Duration.zero &&
        (reason == PlaybackReason.user || autoPlay);

    debugPrint(
      '[PlayerController] performTransition uri=$uri autoPlay=$autoPlay '
      'reason=$reason current=$_selectedPath posMs=${position?.inMilliseconds} '
      'state=$_playerState isPlaying=$_isPlaying switching=$switchingTracks '
      'fadeOnSwitch=${effectiveFadeSettings.fadeOnSwitch} '
      'mode=${effectiveFadeSettings.mode} durationMs=${effectiveFadeSettings.duration.inMilliseconds} '
      'shouldFade=$shouldFade nativeCrossfadeCandidate='
      '${shouldFade && isActivelyPlaying && effectiveFadeSettings.mode == FadeMode.crossfade && _parent.engine.supportsCrossfade}',
    );

    PlaybackTransition strategy = const ImmediateTransition();

    if (shouldFade) {
      if (isActivelyPlaying &&
          effectiveFadeSettings.mode == FadeMode.crossfade &&
          _parent.engine.supportsCrossfade) {
        debugPrint('[PlayerController] transition strategy=NativeCrossfade');
        strategy = NativeCrossfadeTransition(
          duration: effectiveFadeSettings.duration,
        );
      } else {
        // Fallback to sequential fade
        debugPrint(
          '[PlayerController] transition strategy=SequentialFade '
          'isActivelyPlaying=$isActivelyPlaying supportsCrossfade=${_parent.engine.supportsCrossfade}',
        );
        strategy = SequentialFadeTransition(
          duration: effectiveFadeSettings.duration,
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
    _durationReady = false;
    _duration = Duration.zero;
    notifyListeners();

    try {
      debugPrint(
        '[PlayerController] load path=$path nativeVolume=${nativeVolume ?? _volume}',
      );
      await _parent.engine.load(path);
      if (nativeVolume != null || _volume != 1.0) {
        await applyNativeVolume(nativeVolume ?? _volume);
      }
      final duration = await _parent.engine.getDuration();
      _selectedPath = path;
      _position = Duration.zero;
      _duration = duration;
      _durationReady = duration > Duration.zero;
      _lastCommandTime = DateTime.now();
      _isPlaying = false;
      _playerState = PlayerState.ready;

      _onTrackChanged(path);
    } catch (e) {
      setError('Load failed: $e');
    }
    notifyListeners();
  }

  void _onTrackChanged(String? path) {
    if (path == null) {
      _lastFingerprint = null;
      return;
    }

    // Fetch fingerprint in background
    _lastFingerprint = null;
    // _parent.engine.extractFingerprint(path).then((value) {
    //   if (_selectedPath == path) {
    //      debugPrint('Audio Fingerprint for $path: $value');
    //      _lastFingerprint = value;
    //      notifyListeners();
    //   }
    // });
  }

  Future<void> togglePlayPause({FadeSettings? fadeSetting}) async {
    if (_selectedPath == null) return;
    if (_isPlaying) {
      await pause(fadeSetting: fadeSetting);
    } else {
      await play(fadeSetting: fadeSetting);
    }
  }

  Future<void> pause({bool withFade = true, FadeSettings? fadeSetting}) async {
    try {
      final fadeDuration = _pauseResumeFadeDuration(
        withFade: withFade && _isPlaying,
        fadeSetting: fadeSetting,
      );
      await _parent.engine.pause(fadeDuration: fadeDuration);
      _lastCommandTime = DateTime.now();
      _isPlaying = false;
      _playerState = PlayerState.paused;
    } catch (e) {
      setError('Pause failed: $e');
    }
    notifyListeners();
  }

  Future<void> play({bool withFade = true, FadeSettings? fadeSetting}) async {
    if (_selectedPath == null) return;

    if (_playerState == PlayerState.completed) {
      final handled = await _parent.handlePlayRequested();
      if (handled) return;
    }

    try {
      final wasPaused = _playerState == PlayerState.paused;
      final wasReady = _playerState == PlayerState.ready;
      if (_playerState == PlayerState.completed) {
        await seek(Duration.zero);
      }

      final fadeDuration = _playFadeDuration(
        withFade: withFade,
        wasPaused: wasPaused,
        wasReady: wasReady,
        fadeSetting: fadeSetting,
      );
      debugPrint(
        '[PlayerController] play withFade=$withFade wasPaused=$wasPaused '
        'wasReady=$wasReady fadeDurationMs=${fadeDuration?.inMilliseconds ?? 0} '
        'current=$_selectedPath',
      );
      await _parent.engine.play(fadeDuration: fadeDuration);
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
    try {
      debugPrint('[PlayerController] seek targetMs=${target.inMilliseconds}');
      await _parent.engine.seek(target);
      _lastCommandTime = DateTime.now();
      _position = target;
    } catch (e) {
      setError('Seek failed: $e');
    }
    notifyListeners();
  }

  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0);
    await applyNativeVolume(_volume);
    notifyListeners();
  }

  void setFadeSettings(FadeSettings settings) {
    _fadeSettings = settings;
    notifyListeners();
  }

  Duration? _pauseResumeFadeDuration({
    required bool withFade,
    FadeSettings? fadeSetting,
  }) {
    final effectiveFadeSettings = fadeSetting ?? _fadeSettings;
    if (!withFade || !effectiveFadeSettings.fadeOnPauseResume) return null;
    if (effectiveFadeSettings.duration <= Duration.zero) return null;
    return effectiveFadeSettings.duration;
  }

  Duration? _playFadeDuration({
    required bool withFade,
    required bool wasPaused,
    required bool wasReady,
    FadeSettings? fadeSetting,
  }) {
    final effectiveFadeSettings = fadeSetting ?? _fadeSettings;
    if (!withFade || effectiveFadeSettings.duration <= Duration.zero) {
      return null;
    }

    if (wasPaused) {
      return effectiveFadeSettings.fadeOnPauseResume
          ? effectiveFadeSettings.duration
          : null;
    }

    if (wasReady) {
      return effectiveFadeSettings.fadeOnSwitch
          ? effectiveFadeSettings.duration
          : null;
    }

    return null;
  }

  @internal
  Future<void> applyNativeVolume(double volume) async {
    await _parent.engine.setVolume(volume.clamp(0.0, 1.0));
  }

  Future<void> stopPlayback() async {
    _selectedPath = null;
    _position = Duration.zero;
    _duration = Duration.zero;
    _durationReady = false;
    _isPlaying = false;
    _playerState = PlayerState.idle;
    _onTrackChanged(null);
    notifyListeners();
  }

  // --- External Sync Interface ---

  @internal
  void applySnapshot(
    String? path,
    String? playbackState,
    Duration position,
    Duration duration,
    bool isPlaying,
    double nativeVolume, {
    String? error,
  }) {
    if (error != null) {
      setError(error);
      return;
    }

    final now = DateTime.now();
    final recentlyCommanded =
        now.difference(_lastCommandTime) < const Duration(milliseconds: 500);

    // Update duration and volume even if recently commanded.
    _duration = duration;
    _durationReady = duration > Duration.zero;

    _volume = nativeVolume;

    // Guard position and playing state to avoid "jumping" back to old state during command processing
    if (recentlyCommanded) {
      _selectedPath = path;
      _isPlaying = isPlaying;
      if (!isPlaying) {
        _position = position;
        final reachedEnd = playbackState != null
            ? playbackState == 'ENDED'
            : (_selectedPath != null &&
                  _duration > Duration.zero &&
                  _position >= _duration);
        if (_selectedPath != null && reachedEnd) {
          _playerState = PlayerState.completed;
        } else if (_selectedPath != null) {
          _playerState = PlayerState.paused;
        } else {
          _playerState = PlayerState.idle;
        }
      } else {
        _playerState = PlayerState.playing;
      }
      notifyListeners();
      return;
    }

    _selectedPath = path;
    _position = position;
    _isPlaying = isPlaying;

    if (_isPlaying) {
      _playerState = PlayerState.playing;
    } else if (_selectedPath != null &&
        (playbackState != null
            ? playbackState == 'ENDED'
            : (_duration > Duration.zero && _position >= _duration))) {
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
    if (DateTime.now().difference(_lastCommandTime) <
        const Duration(milliseconds: 500)) {
      return;
    }

    _position = position;
    // Completion is now derived from native playback state, not the local
    // render timer, to avoid premature end-of-track transitions.
    notifyListeners();
  }

  @internal
  void updateDuration(Duration duration) {
    _duration = duration;
    _durationReady = duration > Duration.zero;
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
  const SequentialFadeTransition({
    required this.duration,
    required this.targetVolume,
  });
  final Duration duration;
  final double targetVolume;

  @override
  Future<void> execute({
    required PlayerController player,
    required String uri,
    required bool autoPlay,
    Duration? position,
  }) async {
    debugPrint(
      '[SequentialFadeTransition] start uri=$uri autoPlay=$autoPlay '
      'positionMs=${position?.inMilliseconds} durationMs=${duration.inMilliseconds} '
      'initialIsPlaying=${player.isPlaying} currentVolume=${player.volume}',
    );

    await player._parent.engine.transition(
      uri,
      duration,
      position: position,
      autoPlay: autoPlay,
      targetVolume: targetVolume,
    );

    final loadedDuration = await player._parent.engine.getDuration();
    player._selectedPath = uri;
    player._position = position ?? Duration.zero;
    player._duration = loadedDuration;
    player._durationReady = loadedDuration > Duration.zero;
    player._lastCommandTime = DateTime.now();
    player._isPlaying = autoPlay;
    player._playerState = autoPlay ? PlayerState.playing : PlayerState.ready;
    player._onTrackChanged(uri);
    player.notifyListeners();
  }
}

class ImmediateTransition extends PlaybackTransition {
  const ImmediateTransition();
  @override
  Future<void> execute({
    required PlayerController player,
    required String uri,
    required bool autoPlay,
    Duration? position,
  }) async {
    await player.load(uri);
    if (position != null) await player.seek(position);
    if (autoPlay) await player.play(withFade: false);
  }
}

class NativeCrossfadeTransition extends PlaybackTransition {
  const NativeCrossfadeTransition({required this.duration});
  final Duration duration;

  @override
  Future<void> execute({
    required PlayerController player,
    required String uri,
    required bool autoPlay,
    Duration? position,
  }) async {
    // Native crossfade handles current deck management internally in Rust.
    // It starts the new track immediately while the old one keeps playing (fading out).
    debugPrint(
      '[NativeCrossfadeTransition] start uri=$uri autoPlay=$autoPlay '
      'positionMs=${position?.inMilliseconds} durationMs=${duration.inMilliseconds}',
    );
    await player._parent.engine.crossfade(uri, duration, position: position);

    // We update local state immediately
    player._selectedPath = uri;
    player._position = position ?? Duration.zero;
    if (autoPlay) {
      player._isPlaying = true;
      player._playerState = PlayerState.playing;
    }
    player._onTrackChanged(uri);
    player.notifyListeners();
    debugPrint(
      '[NativeCrossfadeTransition] done uri=$uri selected=${player.currentPath} '
      'isPlaying=${player.isPlaying} state=${player.currentState}',
    );
  }
}
