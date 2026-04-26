import 'dart:typed_data';

import 'rust/api/simple/metadata.dart' as rust;

const int generatedArtworkThumbnailSize = 300;

class TrackArtworkOptions {
  const TrackArtworkOptions({
    this.thumbnailSize = generatedArtworkThumbnailSize,
    this.hueCohesion = 0.0,
    this.paletteBlurRadius = 5.0,
    this.meshMuddyPenaltyMultiplier = 1.0,
    this.meshPopulationStrength = 1.0,
    this.meshContrastStrength = 1.0,
    this.meshHarmonyStrength = 1.0,
    this.meshVibrancyStrength = 1.0,
  });

  final int thumbnailSize;
  final double hueCohesion;
  final double paletteBlurRadius;
  final double meshMuddyPenaltyMultiplier;
  final double meshPopulationStrength;
  final double meshContrastStrength;
  final double meshHarmonyStrength;
  final double meshVibrancyStrength;
}

class GeneratedTrackArtwork {
  const GeneratedTrackArtwork({
    required this.artworkFound,
    this.artworkPath,
    this.thumbnailPath,
    this.artworkWidth,
    this.artworkHeight,
    this.themeColorsBlob,
    this.meshDebugBlob,
  });

  final bool artworkFound;
  final String? artworkPath;
  final String? thumbnailPath;
  final int? artworkWidth;
  final int? artworkHeight;
  final Uint8List? themeColorsBlob;
  final Uint8List? meshDebugBlob;

  factory GeneratedTrackArtwork.fromRust(rust.TrackArtworkResult result) {
    return GeneratedTrackArtwork(
      artworkFound: result.artworkFound,
      artworkPath: result.artworkPath,
      thumbnailPath: result.thumbnailPath,
      artworkWidth: result.artworkWidth,
      artworkHeight: result.artworkHeight,
      themeColorsBlob: result.themeColorsBlob,
      meshDebugBlob: result.meshDebugBlob,
    );
  }

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'artworkFound': artworkFound,
      'artworkPath': artworkPath,
      'thumbnailPath': thumbnailPath,
      'artworkWidth': artworkWidth,
      'artworkHeight': artworkHeight,
      'themeColorsBlob': themeColorsBlob,
      'meshDebugBlob': meshDebugBlob,
    };
  }

  factory GeneratedTrackArtwork.fromMap(Map<Object?, Object?> map) {
    int? readInt(Object? value) {
      if (value is int) return value;
      if (value is num) return value.toInt();
      return null;
    }

    Uint8List? readBytes(Object? value) {
      if (value is Uint8List) return value;
      if (value is List<int>) return Uint8List.fromList(value);
      return null;
    }

    return GeneratedTrackArtwork(
      artworkFound: map['artworkFound'] as bool? ?? false,
      artworkPath: map['artworkPath'] as String?,
      thumbnailPath: map['thumbnailPath'] as String?,
      artworkWidth: readInt(map['artworkWidth']),
      artworkHeight: readInt(map['artworkHeight']),
      themeColorsBlob: readBytes(map['themeColorsBlob']),
      meshDebugBlob: readBytes(map['meshDebugBlob']),
    );
  }
}
