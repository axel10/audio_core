import 'playlist_models.dart';

/// A single media item discovered from Android's MediaStore.
class AndroidMediaLibraryEntry {
  const AndroidMediaLibraryEntry({
    required this.id,
    required this.uri,
    required this.filePath,
    required this.title,
    required this.folderPath,
    this.displayName,
    this.artist,
    this.album,
    this.durationMs,
    this.bucketDisplayName,
    this.mimeType,
    this.trackNumber,
  });

  final String id;
  final String uri;
  final String? filePath;
  final String title;
  final String folderPath;
  final String? displayName;
  final String? artist;
  final String? album;
  final int? durationMs;
  final String? bucketDisplayName;
  final String? mimeType;

  /// MediaStore 里的音轨号（正整数）。
  ///
  /// 目录代表封面靠它决定「先试哪首歌」；没有标签或列未填充时为 null。
  /// 与数据库读到的标签音轨号并存，由使用方决定优先级（DB 更权威）。
  final int? trackNumber;

  Duration get duration => Duration(
    milliseconds: durationMs == null
        ? 0
        : durationMs!.clamp(0, 1 << 31).toInt(),
  );

  String get label => title.trim().isEmpty
      ? (displayName?.trim().isNotEmpty == true
            ? displayName!.trim()
            : (filePath ?? uri))
      : title.trim();

  AudioTrack toAudioTrack() {
    final playbackPath = filePath ?? uri;
    return AudioTrack(
      id: id,
      uri: playbackPath,
      title: label,
      artist: artist,
      album: album,
      duration: durationMs == null ? null : Duration(milliseconds: durationMs!),
      metadata: <String, Object?>{
        'isLike': false,
        'playCount': 0,
        'folderPath': folderPath,
        'mediaUri': uri,
        if (filePath != null) 'filePath': filePath,
        if (displayName != null) 'displayName': displayName,
        if (bucketDisplayName != null) 'bucketDisplayName': bucketDisplayName,
        if (mimeType != null) 'mimeType': mimeType,
      },
    );
  }

  factory AndroidMediaLibraryEntry.fromMap(Map<Object?, Object?> map) {
    return AndroidMediaLibraryEntry(
      id: map['id']?.toString() ?? '',
      uri: map['uri']?.toString() ?? '',
      filePath: map['filePath']?.toString(),
      title:
          map['title']?.toString() ??
          map['displayName']?.toString() ??
          'Unknown title',
      folderPath: _normalizeFolderPath(map['relativePath']?.toString() ?? ''),
      displayName: map['displayName']?.toString(),
      artist: map['artist']?.toString(),
      album: map['album']?.toString(),
      durationMs: (map['durationMs'] as num?)?.toInt(),
      bucketDisplayName: map['bucketDisplayName']?.toString(),
      mimeType: map['mimeType']?.toString(),
      trackNumber: _parseTrackNumber(map['trackNumber']),
    );
  }
}

/// 兼容旧版原生插件直接透传的原始值：可能是 `"3/12"`、0、空串或非法文本。
int? _parseTrackNumber(Object? value) {
  if (value == null) return null;
  if (value is num) {
    final parsed = value.toInt();
    return parsed > 0 ? parsed : null;
  }
  final raw = value.toString().trim();
  if (raw.isEmpty) return null;
  final parsed = int.tryParse(raw.split('/').first.trim());
  return (parsed != null && parsed > 0) ? parsed : null;
}

/// Strongly typed result for an Android media library scan.
class AndroidMediaLibraryScanResult {
  const AndroidMediaLibraryScanResult({
    required this.permissionGranted,
    required this.entries,
    this.errorCode,
    this.errorMessage,
  });

  final bool permissionGranted;
  final List<AndroidMediaLibraryEntry> entries;
  final String? errorCode;
  final String? errorMessage;

  bool get isSuccessful => errorCode == null;
  bool get hasEntries => entries.isNotEmpty;
}

String _normalizeFolderPath(String path) {
  final cleaned = path.replaceAll('\\', '/').trim();
  if (cleaned.isEmpty) return '';
  return cleaned.endsWith('/')
      ? cleaned.substring(0, cleaned.length - 1)
      : cleaned;
}
