import 'dart:async';

import 'package:flutter/foundation.dart';

import 'audio_engine/audio_engine_interface.dart';
import 'player_controller.dart';
import 'player_models.dart';
import 'playlist_controller.dart';
import 'playlist_models.dart';

@visibleForTesting
bool shouldAutoAdvanceFromStatus(AudioStatus status) {
  return status.playbackState == 'ENDED';
}

final class AudioCorePlaybackCoordinator {
  AudioCorePlaybackCoordinator({
    required PlayerController player,
    required PlaylistController playlist,
    required Future<void> Function({
      required bool autoPlay,
      Duration? position,
      PlaybackReason reason,
      FadeSettings? fadeSetting,
    })
    loadTrack,
    required VoidCallback notifyListeners,
  }) : _player = player,
       _playlist = playlist,
       _loadTrack = loadTrack,
       _notifyListeners = notifyListeners;

  final PlayerController _player;
  final PlaylistController _playlist;
  final Future<void> Function({
    required bool autoPlay,
    Duration? position,
    PlaybackReason reason,
    FadeSettings? fadeSetting,
  })
  _loadTrack;
  final VoidCallback _notifyListeners;

  bool _isTransitioning = false;
  String? _lastEndedAutoAdvancePath;

  bool get isTransitioning => _isTransitioning;

  void updateTransitioning(bool value) {
    if (_isTransitioning == value) return;
    _isTransitioning = value;
    _notifyListeners();
  }

  void clearEndedTracking() {
    _lastEndedAutoAdvancePath = null;
  }

  void reset() {
    _isTransitioning = false;
    _lastEndedAutoAdvancePath = null;
  }

  void handlePlaybackStatusUpdate(AudioStatus status) {
    final currentPath = _player.currentPath;
    if (status.playbackState == 'ENDED' &&
        status.path != null &&
        currentPath != null &&
        status.path != currentPath) {
      debugPrint(
        '[AudioCoreController] ignoring stale ENDED from ${status.path} '
        'while current path is $currentPath',
      );
      return;
    }

    var adjustedPosition = status.position;
    final updateTimeMs = status.updateTimeSinceEpochMs;
    if (updateTimeMs != null && status.isPlaying) {
      final offset = DateTime.now().millisecondsSinceEpoch - updateTimeMs;
      if (offset > 0) {
        adjustedPosition += Duration(milliseconds: offset);
      }
    }

    _player.applySnapshot(
      status.path,
      status.playbackState,
      adjustedPosition,
      status.duration,
      status.isPlaying,
      status.volume,
      error: status.error,
    );

    if (shouldAutoAdvanceFromStatus(status)) {
      final endedPath = status.path;
      if (endedPath == null || endedPath != _lastEndedAutoAdvancePath) {
        _lastEndedAutoAdvancePath = endedPath;
        unawaited(handleAutoTransition());
      }
    } else if (status.playbackState != 'ENDED' &&
        _player.currentState != PlayerState.completed) {
      _lastEndedAutoAdvancePath = null;
    }
  }

  Future<void> handleAutoTransition() async {
    if (_isTransitioning || _player.currentState != PlayerState.completed) {
      debugPrint(
        '[AudioCoreController] autoTransition skipped '
        'isTransitioning=$_isTransitioning playerState=${_player.currentState} '
        'currentPath=${_player.currentPath ?? "nil"}',
      );
      return;
    }

    debugPrint(
      '[AudioCoreController] autoTransition mode=${_playlist.mode} '
      'current=${_playlist.currentTrack?.id} next=${_playlist.nextTrack?.id} '
      'lastEnded=$_lastEndedAutoAdvancePath',
    );

    if (_playlist.mode == PlaylistMode.singleLoop) {
      await _loadTrack(autoPlay: true, reason: PlaybackReason.autoNext);
      return;
    }

    if (_playlist.mode == PlaylistMode.single) return;

    final success = await _playlist.playNext(reason: PlaybackReason.autoNext);
    if (!success) {
      // End of queue logic could go here
    }
  }
}
