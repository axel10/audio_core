class GeneratedTrackArtwork {
  const GeneratedTrackArtwork({
    required this.artworkFound,
    this.artworkPath,
    this.thumbnailPath,
    this.artworkWidth,
    this.artworkHeight,
  });

  final bool artworkFound;
  final String? artworkPath;
  final String? thumbnailPath;
  final int? artworkWidth;
  final int? artworkHeight;

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'artworkFound': artworkFound,
      'artworkPath': artworkPath,
      'thumbnailPath': thumbnailPath,
      'artworkWidth': artworkWidth,
      'artworkHeight': artworkHeight,
    };
  }

  factory GeneratedTrackArtwork.fromMap(Map<Object?, Object?> map) {
    int? readInt(Object? value) {
      if (value is int) return value;
      if (value is num) return value.toInt();
      return null;
    }

    return GeneratedTrackArtwork(
      artworkFound: map['artworkFound'] as bool? ?? false,
      artworkPath: map['artworkPath'] as String?,
      thumbnailPath: map['thumbnailPath'] as String?,
      artworkWidth: readInt(map['artworkWidth']),
      artworkHeight: readInt(map['artworkHeight']),
    );
  }
}
