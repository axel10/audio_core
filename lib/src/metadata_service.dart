import 'audio_details.dart';
import 'audio_engine/flutter_taglib_metadata_bridge.dart';
import 'track_metadata.dart';
import 'track_metadata_update.dart';

abstract interface class MetadataService {
  Future<bool> updateTrackMetadata({
    required String path,
    required Map<String, Object?> metadata,
  });

  Future<List<bool>> updateTrackMetadataBatch({
    required List<TrackMetadataWriteRequest> requests,
  });

  Future<List<bool>> copyTrackMetadataBatch({
    required List<TrackMetadataCopyRequest> requests,
  });

  Future<TrackMetadata> getTrackMetadata({
    required String path,
    String? fallbackMediaUri,
  });

  Future<AudioDetails> getAudioDetails({
    required String path,
    String? fallbackMediaUri,
  });

  Future<void> removeAllTags({required String path, String? fallbackMediaUri});
}

final class FlutterTaglibMetadataService implements MetadataService {
  const FlutterTaglibMetadataService();

  @override
  Future<bool> updateTrackMetadata({
    required String path,
    required Map<String, Object?> metadata,
  }) async {
    return updateTrackMetadataWithFlutterTaglib(
      path: path,
      metadata: metadata,
      fallbackMediaUri: metadata['fallbackMediaUri'] as String?,
    );
  }

  @override
  Future<List<bool>> updateTrackMetadataBatch({
    required List<TrackMetadataWriteRequest> requests,
  }) async {
    return updateTrackMetadataBatchWithFlutterTaglib(requests: requests);
  }

  @override
  Future<List<bool>> copyTrackMetadataBatch({
    required List<TrackMetadataCopyRequest> requests,
  }) async {
    return copyTrackMetadataBatchWithFlutterTaglib(requests: requests);
  }

  @override
  Future<TrackMetadata> getTrackMetadata({
    required String path,
    String? fallbackMediaUri,
  }) async {
    try {
      final metadata = await readTrackMetadataWithFlutterTaglib(
        path,
        fallbackMediaUri: fallbackMediaUri,
      );
      return metadata ??
          TrackMetadata(
            error: 'Failed to read metadata via flutter_taglib.',
            genres: const <String>[],
            pictures: const [],
          );
    } catch (e) {
      return TrackMetadata(
        error: e.toString(),
        genres: const <String>[],
        pictures: const [],
      );
    }
  }

  @override
  Future<AudioDetails> getAudioDetails({
    required String path,
    String? fallbackMediaUri,
  }) async {
    return getAudioDetailsWithFlutterTaglib(
      path: path,
      fallbackMediaUri: fallbackMediaUri,
    );
  }

  @override
  Future<void> removeAllTags({
    required String path,
    String? fallbackMediaUri,
  }) async {
    final success = await removeAllTagsWithFlutterTaglib(
      path,
      fallbackMediaUri: fallbackMediaUri,
    );
    if (!success) {
      throw StateError('Failed to remove tags via flutter_taglib.');
    }
  }
}
