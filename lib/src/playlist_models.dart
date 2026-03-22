/// A track item used by playlist APIs.
class AudioTrack {
  const AudioTrack({
    required this.id,
    required this.uri,
    this.title,
    this.artist,
    this.album,
    this.duration,
    this.metadata = const <String, Object?>{},
  });

  /// Stable unique track id.
  final String id;

  /// Audio URI/path understood by the plugin.
  final String uri;

  /// Optional display title.
  final String? title;

  /// Optional artist name.
  final String? artist;

  /// Optional album name.
  final String? album;

  /// Optional known duration.
  final Duration? duration;

  /// Optional custom metadata for user-defined strategies.
  final Map<String, Object?> metadata;

  /// Alias for legacy callers.
  @Deprecated('Use metadata instead.')
  Map<String, Object?> get extras => metadata;

  /// Returns a typed metadata value if it exists and matches [T].
  T? metadataValue<T>(String key) {
    final value = metadata[key];
    return value is T ? value : null;
  }
}

/// A collection of audio tracks with metadata.
class Playlist {
  const Playlist({required this.id, required this.name, required this.items});

  /// Unique playlist identifier.
  final String id;

  /// Display name of the playlist.
  final String name;

  /// List of tracks in this playlist.
  final List<AudioTrack> items;

  /// Creates a copy with optionally replaced fields.
  Playlist copyWith({String? id, String? name, List<AudioTrack>? items}) {
    return Playlist(
      id: id ?? this.id,
      name: name ?? this.name,
      items: items ?? this.items,
    );
  }
}

extension AudioTrackCopy on AudioTrack {
  /// Creates a copy with optionally replaced fields.
  AudioTrack copyWith({
    String? id,
    String? uri,
    String? title,
    String? artist,
    String? album,
    Duration? duration,
    Map<String, Object?>? metadata,
  }) {
    return AudioTrack(
      id: id ?? this.id,
      uri: uri ?? this.uri,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      duration: duration ?? this.duration,
      metadata: metadata ?? this.metadata,
    );
  }
}

/// Playback mode for the playlist.
enum PlaylistMode {
  /// 单曲播放：播放完当前歌曲后停止。
  single,

  /// 单曲循环：不断重复当前歌曲。
  singleLoop,

  /// 队列播放：顺序播放当前队列，播完最后一首后停止。
  queue,

  /// 队列循环：顺序播放当前队列，播完最后一首后回到第一首继续。
  queueLoop,

  /// 自动队列循环：播完当前队列后，自动加载并播放下一个播放列表。
  autoQueueLoop,
}

/// Repeat behavior used by playlist playback.
/// @deprecated Use [PlaylistMode] instead.
enum RepeatMode { off, one, all }

/// Reason for a track transition.
enum PlaybackReason { user, autoNext, ended, playlistChanged }
