import 'playlist_models.dart';

/// A single media item discovered from iOS `MPMediaLibrary`.
class IosMediaLibraryEntry {
  const IosMediaLibraryEntry({
    required this.id,
    required this.uri,
    required this.title,
    this.artist,
    this.album,
    this.albumArtist,
    this.genre,
    this.durationMs,
    this.trackNumber,
    this.discNumber,
  });

  /// `MPMediaItem.persistentID` as a decimal string.
  final String id;

  /// `ipod-library://...` asset URL.
  final String uri;

  final String title;
  final String? artist;
  final String? album;
  final String? albumArtist;
  final String? genre;
  final int? durationMs;
  final int? trackNumber;
  final int? discNumber;

  Duration get duration => Duration(
        milliseconds:
            durationMs == null ? 0 : durationMs!.clamp(0, 1 << 31).toInt(),
      );

  String get label => title.trim().isEmpty ? uri : title.trim();

  AudioTrack toAudioTrack() {
    return AudioTrack(
      id: id,
      uri: uri,
      title: label,
      artist: artist,
      album: album,
      duration: durationMs == null ? null : Duration(milliseconds: durationMs!),
      metadata: <String, Object?>{
        'isLike': false,
        'playCount': 0,
        'iosPersistentId': id,
        'mediaUri': uri,
        if (albumArtist != null) 'albumArtist': albumArtist,
        if (genre != null) 'genre': genre,
        if (trackNumber != null) 'trackNumber': trackNumber,
        if (discNumber != null) 'discNumber': discNumber,
      },
    );
  }

  factory IosMediaLibraryEntry.fromMap(Map<Object?, Object?> map) {
    int? parseInt(Object? value) {
      if (value is int) return value;
      if (value is num) return value.toInt();
      if (value is String) return int.tryParse(value);
      return null;
    }

    String? parseNonEmptyString(Object? value) {
      final s = value?.toString().trim();
      return (s == null || s.isEmpty) ? null : s;
    }

    return IosMediaLibraryEntry(
      id: map['id']?.toString() ?? '',
      uri: map['uri']?.toString() ?? '',
      title: parseNonEmptyString(map['title']) ?? 'Unknown title',
      artist: parseNonEmptyString(map['artist']),
      album: parseNonEmptyString(map['album']),
      albumArtist: parseNonEmptyString(map['albumArtist']),
      genre: parseNonEmptyString(map['genre']),
      durationMs: parseInt(map['durationMs']),
      trackNumber: parseInt(map['trackNumber']),
      discNumber: parseInt(map['discNumber']),
    );
  }
}

/// Result returned by [AudioCoreController.scanIosMediaLibrary].
class IosMediaLibraryScanResult {
  const IosMediaLibraryScanResult({
    required this.permissionGranted,
    required this.entries,
    this.errorCode,
    this.errorMessage,
  });

  final bool permissionGranted;
  final List<IosMediaLibraryEntry> entries;
  final String? errorCode;
  final String? errorMessage;

  bool get isSuccessful => permissionGranted && errorCode == null;
}
