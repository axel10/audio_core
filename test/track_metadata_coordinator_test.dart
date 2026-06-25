import 'dart:io';

import 'package:audio_core/src/audio_details.dart';
import 'package:audio_core/src/audio_engine/audio_file_access.dart';
import 'package:audio_core/src/rust/api/simple/metadata.dart' as rust_meta;
import 'package:audio_core/src/metadata_service.dart';
import 'package:audio_core/src/track_metadata.dart';
import 'package:audio_core/src/track_metadata_coordinator.dart';
import 'package:audio_core/src/track_metadata_update.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TrackMetadataCoordinator', () {
    late Directory tempDir;
    late _FakeFileAccess engine;
    late _FakeMetadataService metadataService;
    late List<String> errors;
    late int notificationCount;
    late String? currentPath;
    late TrackMetadataCoordinator coordinator;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync(
        'track_metadata_coordinator_test',
      );
      engine = _FakeFileAccess();
      metadataService = _FakeMetadataService();
      errors = <String>[];
      notificationCount = 0;
      currentPath = null;
      coordinator = TrackMetadataCoordinator(
        fileAccess: engine,
        metadataService: metadataService,
        currentPlaybackPath: () => currentPath,
        notifyListeners: () {
          notificationCount++;
        },
        reportError: errors.add,
      );
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('should sync writes when the target path matches playback', () async {
      final trackFile = File('${tempDir.path}/current.mp3');
      trackFile.writeAsStringSync('content');
      currentPath = trackFile.path;

      final success = await coordinator.updateMetadata(
        path: trackFile.path,
        fallbackMediaUri: 'content://media/current',
        metadata: const TrackMetadataUpdate(
          title: 'New title',
          clearTrackNumber: true,
        ),
        clearBeforeWrite: true,
      );

      expect(success, isTrue);
      expect(engine.prepareForFileWriteCalls, 1);
      expect(engine.finishFileWriteCalls, 1);
      expect(metadataService.removeAllTagsCalls, 1);
      expect(metadataService.updateTrackMetadataCalls, 1);
      expect(notificationCount, 1);
      expect(errors, isEmpty);
      expect(metadataService.lastUpdatePath, trackFile.path);
      expect(metadataService.lastUpdateMetadata['title'], 'New title');
      expect(
        metadataService.lastUpdateMetadata['fallbackMediaUri'],
        'content://media/current',
      );
      expect(metadataService.lastUpdateMetadata['clearBeforeWrite'], isTrue);
    });

    test('should not sync writes when the target path is unrelated', () async {
      final currentTrackFile = File('${tempDir.path}/current.mp3');
      currentTrackFile.writeAsStringSync('content');
      currentPath = currentTrackFile.path;

      final targetFile = File('${tempDir.path}/other.mp3');
      targetFile.writeAsStringSync('content');
      metadataService.updateTrackMetadataBatchResult = [true];

      final success = await coordinator.updateMetadataBatch(
        requests: [
          TrackMetadataWriteRequest(
            path: targetFile.path,
            metadata: const TrackMetadataUpdate(title: 'Batch title'),
          ),
        ],
      );

      expect(success, [true]);
      expect(engine.prepareForFileWriteCalls, 0);
      expect(engine.finishFileWriteCalls, 0);
      expect(metadataService.updateTrackMetadataBatchCalls, 1);
      expect(notificationCount, 1);
      expect(errors, isEmpty);
      expect(metadataService.lastBatchRequests, hasLength(1));
      expect(metadataService.lastBatchRequests.single.path, targetFile.path);
    });

    test('should preserve batch copy order and sync only once', () async {
      final sourceFile = File('${tempDir.path}/source.mp3');
      sourceFile.writeAsStringSync('content');
      final targetFile = File('${tempDir.path}/target.mp3');
      targetFile.writeAsStringSync('content');
      currentPath = targetFile.path;

      metadataService.copyTrackMetadataBatchResult = [false];

      final result = await coordinator.copyMetadataBatch(
        requests: [
          TrackMetadataCopyRequest(
            sourcePath: '  ${sourceFile.path}  ',
            targetPath: '  ${targetFile.path}  ',
          ),
        ],
      );

      expect(result, [false]);
      expect(engine.prepareForFileWriteCalls, 1);
      expect(engine.finishFileWriteCalls, 1);
      expect(metadataService.copyTrackMetadataBatchCalls, 1);
      expect(notificationCount, 1);
      expect(errors, isEmpty);
      expect(metadataService.lastCopyRequests, hasLength(1));
      expect(
        metadataService.lastCopyRequests.single.sourcePath,
        sourceFile.path,
      );
      expect(
        metadataService.lastCopyRequests.single.targetPath,
        targetFile.path,
      );
    });
  });
}

final class _FakeFileAccess extends Fake implements AudioFileAccess {
  int prepareForFileWriteCalls = 0;
  int finishFileWriteCalls = 0;

  @override
  Future<void> prepareForFileWrite() async {
    prepareForFileWriteCalls++;
  }

  @override
  Future<void> finishFileWrite() async {
    finishFileWriteCalls++;
  }

  @override
  Future<bool> registerPersistentAccess(String path) async => false;

  @override
  Future<void> forgetPersistentAccess(String path) async {}

  @override
  Future<bool> hasPersistentAccess(String path) async => false;

  @override
  Future<List<String>> listPersistentAccessPaths() async => const <String>[];

  @override
  Future<bool> beginScopedAccess(String path) async => false;

  @override
  Future<void> endScopedAccess(String path) async {}
}

final class _FakeMetadataService extends Fake implements MetadataService {
  int updateTrackMetadataCalls = 0;
  int updateTrackMetadataBatchCalls = 0;
  int copyTrackMetadataBatchCalls = 0;
  int removeAllTagsCalls = 0;

  String? lastUpdatePath;
  Map<String, Object?> lastUpdateMetadata = const <String, Object?>{};
  List<TrackMetadataWriteRequest> lastBatchRequests =
      const <TrackMetadataWriteRequest>[];
  List<TrackMetadataCopyRequest> lastCopyRequests =
      const <TrackMetadataCopyRequest>[];

  List<bool> updateTrackMetadataBatchResult = const <bool>[];
  List<bool> copyTrackMetadataBatchResult = const <bool>[];
  bool updateTrackMetadataResult = true;

  @override
  Future<bool> updateTrackMetadata({
    required String path,
    required Map<String, Object?> metadata,
  }) async {
    updateTrackMetadataCalls++;
    lastUpdatePath = path;
    lastUpdateMetadata = Map<String, Object?>.from(metadata);
    return updateTrackMetadataResult;
  }

  @override
  Future<List<bool>> updateTrackMetadataBatch({
    required List<TrackMetadataWriteRequest> requests,
  }) async {
    updateTrackMetadataBatchCalls++;
    lastBatchRequests = List<TrackMetadataWriteRequest>.unmodifiable(requests);
    return List<bool>.from(updateTrackMetadataBatchResult);
  }

  @override
  Future<List<bool>> copyTrackMetadataBatch({
    required List<TrackMetadataCopyRequest> requests,
  }) async {
    copyTrackMetadataBatchCalls++;
    lastCopyRequests = List<TrackMetadataCopyRequest>.unmodifiable(requests);
    return List<bool>.from(copyTrackMetadataBatchResult);
  }

  @override
  Future<TrackMetadata> getTrackMetadata({
    required String path,
    String? fallbackMediaUri,
  }) async {
    return const TrackMetadata(
      genres: <String>[],
      pictures: <rust_meta.TrackPicture>[],
    );
  }

  @override
  Future<AudioDetails> getAudioDetails({
    required String path,
    String? fallbackMediaUri,
  }) async {
    return const AudioDetails(
      formatName: 'test',
      codecName: 'test',
      duration: Duration.zero,
      bitrate: 0,
      sampleRate: 0,
      channels: 0,
      bitrateMode: 'unknown',
      fileSize: 0,
    );
  }

  @override
  Future<void> removeAllTags({
    required String path,
    String? fallbackMediaUri,
  }) async {
    removeAllTagsCalls++;
  }
}
