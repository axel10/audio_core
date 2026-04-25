import '../rust/api/simple_api.dart' as rust;
import '../track_artwork.dart';

mixin TrackArtworkSupport {
  String normalizeArtworkPath(String path);

  Future<GeneratedTrackArtwork> generateTrackArtwork({
    required String path,
    required String cacheRootPath,
    required bool saveLargeArtwork,
    TrackArtworkOptions options = const TrackArtworkOptions(),
  }) async {
    final result = await rust.generateTrackArtwork(
      path: normalizeArtworkPath(path),
      cacheRootPath: normalizeArtworkPath(cacheRootPath),
      saveLargeArtwork: saveLargeArtwork,
      thumbnailSize: options.thumbnailSize,
      hueCohesion: options.hueCohesion,
      meshMuddyPenaltyMultiplier: options.meshMuddyPenaltyMultiplier,
    );
    return GeneratedTrackArtwork.fromRust(result);
  }
}
