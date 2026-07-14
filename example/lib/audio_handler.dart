import 'package:audio_service/audio_service.dart';
import 'package:audio_core/audio_core.dart';

/// A wrapper around [AudioCoreController] that implements [BaseAudioHandler]
/// to provide Android notification bar and media controls.
class AudioCoreHandler extends BaseAudioHandler with QueueHandler {
  final AudioCoreController controller;
  String? _lastPlaybackStateKey;
  String? _lastQueueKey;
  String? _lastMediaItemKey;

  AudioCoreHandler(this.controller) {
    // Listen to changes and update media state
    controller.player.addListener(_updatePlaybackState);
    controller.playlist.addListener(_updateQueue);
    controller.addListener(_updateMetadata);

    // Initial state sync
    _updatePlaybackState();
    _updateQueue();
    _updateMetadata();
  }

  void _updatePlaybackState() {
    final key = [
      controller.player.currentState.name,
      controller.player.isPlaying,
      controller.player.currentPath ?? '',
      controller.playlist.currentIndex?.toString() ?? 'null',
      controller.player.duration.inSeconds.toString(),
      controller.player.playbackSpeed.toString(),
    ].join('|');

    if (key == _lastPlaybackStateKey) {
      return;
    }
    _lastPlaybackStateKey = key;

    final state = controller.player.currentState;

    // Determine processing state
    AudioProcessingState processingState;
    switch (state) {
      case PlayerState.idle:
        processingState = AudioProcessingState.idle;
        break;
      case PlayerState.buffering:
        processingState = AudioProcessingState.buffering;
        break;
      case PlayerState.ready:
      case PlayerState.playing:
      case PlayerState.paused:
        processingState = AudioProcessingState.ready;
        break;
      case PlayerState.completed:
        processingState = AudioProcessingState.completed;
        break;
      case PlayerState.error:
        processingState = AudioProcessingState.error;
        break;
    }

    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          MediaControl.skipToPrevious,
          if (controller.player.isPlaying)
            MediaControl.pause
          else
            MediaControl.play,
          MediaControl.stop,
          MediaControl.skipToNext,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        androidCompactActionIndices: const [0, 1, 3],
        processingState: processingState,
        playing: controller.player.isPlaying,
        updatePosition: controller.player.position,
        bufferedPosition: controller.player.position,
        speed: controller.player.playbackSpeed,
        queueIndex: controller.playlist.currentIndex,
      ),
    );
  }

  void _updateQueue() {
    final newQueue = controller.playlist.items.map((track) {
      return MediaItem(
        id: track.id,
        album: track.album ?? 'Unknown Album',
        title: track.title ?? 'Unknown Title',
        artist: track.artist ?? 'Unknown Artist',
        duration: track.duration,
        extras: track.metadata,
      );
    }).toList();

    final key = newQueue
        .map(
          (item) =>
              '${item.id}|${item.title}|${item.artist}|${item.album}|${item.duration?.inMilliseconds ?? 0}',
        )
        .join('::');
    if (key == _lastQueueKey) {
      return;
    }
    _lastQueueKey = key;

    queue.add(newQueue);
  }

  void _updateMetadata() {
    final track = controller.playlist.currentTrack;
    if (track == null) {
      mediaItem.add(null);
      return;
    }

    final key =
        '${track.id}|${track.title}|${track.artist}|${track.album}|${controller.player.duration.inMilliseconds}|${track.duration?.inMilliseconds ?? 0}';
    if (key == _lastMediaItemKey) {
      return;
    }
    _lastMediaItemKey = key;

    // Update mediaItem with combined info from track metadata and player live duration
    mediaItem.add(
      MediaItem(
        id: track.id,
        album: track.album ?? 'Unknown Album',
        title: track.title ?? (track.uri.split('/').last),
        artist: track.artist ?? 'Unknown Artist',
        duration: controller.player.duration > Duration.zero
            ? controller.player.duration
            : track.duration,
        extras: track.metadata,
      ),
    );
  }

  // --- AudioHandler overrides ---

  @override
  Future<void> play() => controller.player.play();

  @override
  Future<void> pause() => controller.player.pause();

  @override
  Future<void> stop() async {
    await controller.player.stopPlayback();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) async {
    await controller.player.seek(position);
    _lastPlaybackStateKey = null;
    _updatePlaybackState();
  }

  @override
  Future<void> skipToNext() => controller.playlist.playNext();

  @override
  Future<void> skipToPrevious() => controller.playlist.playPrevious();

  @override
  Future<void> skipToQueueItem(int index) {
    if (controller.playlist.activePlaylistId != null) {
      return controller.playlist.setActivePlaylist(
        controller.playlist.activePlaylistId!,
        startIndex: index,
        autoPlay: true,
      );
    }
    return Future.value();
  }

  @override
  Future<void> setSpeed(double speed) async {
    await controller.player.setPlaybackSpeed(speed);
    _lastPlaybackStateKey = null;
    _updatePlaybackState();
  }
}
