import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:audio_core/audio_core.dart' hide PlaybackState;
import 'package:flutter_media_session/flutter_media_session.dart';
import 'package:flutter_media_session/flutter_media_session_platform_interface.dart';

/// Production-ready adapter that bridges [AudioCoreController] with [FlutterMediaSession].
class AudioCoreMediaSessionAdapter implements MediaSessionAdapter {
  final AudioCoreController controller;
  final bool manageLifecycle;

  FlutterMediaSession? _session;
  StreamSubscription<MediaAction>? _actionSubscription;

  PlayerState? _lastPlayerState;
  bool? _lastIsPlaying;
  String? _lastTrackId;

  AudioCoreMediaSessionAdapter(
    this.controller, {
    this.manageLifecycle = false,
  });

  @override
  void bind(FlutterMediaSession session) {
    unbind();
    _session = session;

    if (manageLifecycle) {
      _session?.activate().catchError((e) {
        debugPrint('[AudioCoreMediaSessionAdapter] Failed to activate media session: $e');
      });
    }

    controller.player.addListener(_onPlayerOrPlaylistChanged);
    controller.playlist.addListener(_onPlayerOrPlaylistChanged);

    _actionSubscription = FlutterMediaSessionPlatform.instance.onMediaAction
        .listen(_handleMediaAction);

    sync();
    syncAvailableActions();
  }

  @override
  void unbind() {
    controller.player.removeListener(_onPlayerOrPlaylistChanged);
    controller.playlist.removeListener(_onPlayerOrPlaylistChanged);

    _actionSubscription?.cancel();
    _actionSubscription = null;

    if (manageLifecycle) {
      _session?.deactivate().catchError((e) {
        debugPrint('[AudioCoreMediaSessionAdapter] Failed to deactivate media session: $e');
      });
    }
    _session = null;
    _lastPlayerState = null;
    _lastIsPlaying = null;
    _lastTrackId = null;
  }

  void _onPlayerOrPlaylistChanged() {
    final player = controller.player;
    final track = controller.playlist.currentTrack;

    final isPlaying = player.isPlaying;
    final state = player.currentState;
    final trackId = track?.id ?? player.currentPath;

    final changed = _lastIsPlaying != isPlaying ||
        _lastPlayerState != state ||
        _lastTrackId != trackId;

    debugPrint(
      '[AudioCoreMediaSessionAdapter] _onPlayerOrPlaylistChanged: '
      'isPlaying=$isPlaying (was $_lastIsPlaying), '
      'state=$state (was $_lastPlayerState), '
      'trackId=$trackId (was $_lastTrackId) -> changed=$changed',
    );

    // Check if meaningful state or track changed to avoid redundant spam during 60fps rendering
    if (changed) {
      _lastIsPlaying = isPlaying;
      _lastPlayerState = state;
      _lastTrackId = trackId;
      sync();
    }
  }

  /// Synchronizes both metadata and playback state to the system controls.
  void sync() {
    if (_session == null) {
      debugPrint('[AudioCoreMediaSessionAdapter] sync skipped: _session is null');
      return;
    }

    final track = controller.playlist.currentTrack;
    final player = controller.player;

    final duration = player.duration > Duration.zero
        ? player.duration
        : (track?.duration ?? Duration.zero);

    final title = track?.title?.isNotEmpty == true
        ? track!.title!
        : (track != null
            ? Uri.decodeFull(track.uri.split('/').last)
            : (player.currentPath != null
                ? Uri.decodeFull(player.currentPath!.split('/').last)
                : 'No track selected'));
    final artist = track?.artist ?? 'Unknown Artist';
    final album = track?.album ?? 'AudioCore';
    final artworkUri = (track?.metadata['artworkUri'] ??
            track?.metadata['artwork'] ??
            track?.metadata['cover'])
        ?.toString();

    // 1. Update metadata
    debugPrint('[AudioCoreMediaSessionAdapter] updateMetadata: title=$title, artist=$artist, duration=${duration.inMilliseconds}ms');
    FlutterMediaSessionPlatform.instance.updateMetadata(
      MediaMetadata(
        title: title,
        artist: artist,
        album: album,
        artworkUri: artworkUri,
        duration: duration,
      ),
    ).catchError((e) {
      debugPrint('[AudioCoreMediaSessionAdapter] Failed to update metadata: $e');
    });

    // 2. Compute playback status
    PlaybackStatus status = PlaybackStatus.idle;
    if (player.isPlaying) {
      status = (player.currentState == PlayerState.buffering)
          ? PlaybackStatus.buffering
          : PlaybackStatus.playing;
    } else {
      switch (player.currentState) {
        case PlayerState.idle:
          status = PlaybackStatus.idle;
          break;
        case PlayerState.buffering:
          status = PlaybackStatus.buffering;
          break;
        case PlayerState.completed:
          status = PlaybackStatus.ended;
          break;
        case PlayerState.error:
          status = PlaybackStatus.error;
          break;
        case PlayerState.ready:
        case PlayerState.paused:
        case PlayerState.playing:
          status = PlaybackStatus.paused;
          break;
      }
    }

    MediaRepeatMode repeatMode = MediaRepeatMode.none;
    switch (controller.playlist.mode) {
      case PlaylistMode.singleLoop:
        repeatMode = MediaRepeatMode.one;
        break;
      case PlaylistMode.queueLoop:
        repeatMode = MediaRepeatMode.all;
        break;
      case PlaylistMode.single:
      case PlaylistMode.queue:
        repeatMode = MediaRepeatMode.none;
        break;
    }

    // 3. Update playback state
    debugPrint(
      '[AudioCoreMediaSessionAdapter] updatePlaybackState: '
      'status=$status, pos=${player.position.inMilliseconds}ms, speed=${player.playbackSpeed}',
    );
    FlutterMediaSessionPlatform.instance.updatePlaybackState(
      PlaybackState(
        status: status,
        position: player.position,
        speed: player.playbackSpeed,
        repeatMode: repeatMode,
        shuffleModeEnabled: controller.playlist.randomPolicy != null,
      ),
    ).catchError((e) {
      debugPrint('[AudioCoreMediaSessionAdapter] Failed to update playback state: $e');
    });

    syncAvailableActions();
  }

  /// Synchronizes available system actions.
  void syncAvailableActions() {
    if (_session == null) return;

    final hasTrack = controller.playlist.currentTrack != null ||
        controller.player.currentPath != null;

    final actions = <MediaAction>{
      MediaAction.play,
      MediaAction.pause,
      MediaAction.stop,
      MediaAction.seekTo,
      if (hasTrack) MediaAction.skipToNext,
      if (hasTrack) MediaAction.skipToPrevious,
    };

    FlutterMediaSessionPlatform.instance.updateAvailableActions(actions).catchError((e) {
      debugPrint('[AudioCoreMediaSessionAdapter] Failed to update available actions: $e');
    });
  }

  void _handleMediaAction(MediaAction action) async {
    debugPrint('[AudioCoreMediaSessionAdapter] _handleMediaAction received: ${action.name} (seekPosition: ${action.seekPosition})');
    try {
      switch (action.name) {
        case 'play':
          await controller.player.play();
          sync();
          break;
        case 'pause':
          await controller.player.pause();
          sync();
          break;
        case 'togglePlayPause':
          await controller.player.togglePlayPause();
          sync();
          break;
        case 'stop':
          await controller.player.stopPlayback();
          sync();
          break;
        case 'seekTo':
          if (action.seekPosition != null) {
            await controller.player.seek(action.seekPosition!);
            sync();
          }
          break;
        case 'skipToNext':
          await controller.playlist.playNext();
          sync();
          break;
        case 'skipToPrevious':
          await controller.playlist.playPrevious();
          sync();
          break;
        case 'repeat':
          final currentMode = controller.playlist.mode;
          final nextMode = switch (currentMode) {
            PlaylistMode.queue => PlaylistMode.queueLoop,
            PlaylistMode.queueLoop => PlaylistMode.singleLoop,
            PlaylistMode.singleLoop => PlaylistMode.single,
            PlaylistMode.single => PlaylistMode.queue,
          };
          controller.playlist.setMode(nextMode);
          sync();
          break;
        case 'shuffle':
          sync();
          break;
      }
    } catch (e) {
      debugPrint('[AudioCoreMediaSessionAdapter] Error handling action ${action.name}: $e');
    }
  }
}
