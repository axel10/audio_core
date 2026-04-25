import '../rust/api/simple_api.dart' as rust;
import '../track_artwork.dart';

mixin TrackArtworkSupport {
  String normalizeArtworkPath(String path);

  Future<GeneratedTrackArtwork> generateTrackArtwork({
    required String path,
    required String cacheRootPath,
    required bool saveLargeArtwork,
    int thumbnailSize = generatedArtworkThumbnailSize,
    double hueCohesion = 0.0,
    double meshMuddyPenaltyMultiplier = 1.0,
  }) async {
    final result = await rust.generateTrackArtwork(
      path: normalizeArtworkPath(path),
      cacheRootPath: normalizeArtworkPath(cacheRootPath),
      saveLargeArtwork: saveLargeArtwork,
      thumbnailSize: thumbnailSize,
      hueCohesion: hueCohesion,
      meshMuddyPenaltyMultiplier: meshMuddyPenaltyMultiplier,
    );
    return GeneratedTrackArtwork.fromRust(result);
  }
}
