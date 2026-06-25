import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_taglib/flutter_taglib.dart' as taglib;

import 'audio_details.dart';
import 'audio_engine/audio_file_access.dart';
import 'metadata_service.dart';
import 'track_metadata.dart';
import 'track_metadata_update.dart';

final class TrackMetadataCoordinator {
  TrackMetadataCoordinator({
    required AudioFileAccess fileAccess,
    required MetadataService metadataService,
    required String? Function() currentPlaybackPath,
    required VoidCallback notifyListeners,
    required void Function(String message) reportError,
  }) : _fileAccess = fileAccess,
       _metadataService = metadataService,
       _currentPlaybackPath = currentPlaybackPath,
       _notifyListeners = notifyListeners,
       _reportError = reportError;

  final AudioFileAccess _fileAccess;
  final MetadataService _metadataService;
  final String? Function() _currentPlaybackPath;
  final VoidCallback _notifyListeners;
  final void Function(String message) _reportError;

  Future<void> removeAllTags({
    required String path,
    String? fallbackMediaUri,
  }) async {
    await _metadataService.removeAllTags(
      path: path,
      fallbackMediaUri: fallbackMediaUri,
    );
  }

  Future<TrackMetadata> getTrackMetadata({
    required String path,
    String? fallbackMediaUri,
  }) async {
    return _metadataService.getTrackMetadata(
      path: path,
      fallbackMediaUri: fallbackMediaUri,
    );
  }

  Future<AudioDetails> getAudioDetails({
    required String path,
    String? fallbackMediaUri,
  }) async {
    return _metadataService.getAudioDetails(
      path: path,
      fallbackMediaUri: fallbackMediaUri,
    );
  }

  Future<bool> updateMetadata({
    required String path,
    String? fallbackMediaUri,
    required TrackMetadataUpdate metadata,
    bool clearBeforeWrite = false,
  }) async {
    final file = path.startsWith('content://') ? null : File(path);
    if (file != null && !file.existsSync()) {
      debugPrint(
        '[AudioCore][Metadata] updateMetadata: File does not exist: $path',
      );
      return false;
    }

    if (file != null && await _isFileOccupied(path)) {
      taglib.TagLibFile.lastError = 'file_occupied';
      debugPrint('[AudioCore][Metadata] File occupied by another app: $path');
      return false;
    }

    final needsSync = _needsMetadataWriteSyncForPath(path);
    return _runWriteOperation(
      needsSync: needsSync,
      operation: () async {
        if (clearBeforeWrite && !Platform.isAndroid) {
          await _metadataService.removeAllTags(
            path: path,
            fallbackMediaUri: fallbackMediaUri,
          );
        }

        final success = await _metadataService.updateTrackMetadata(
          path: path,
          metadata: <String, Object?>{
            ...metadata.toMap(includeEmptyCollections: clearBeforeWrite),
            'fallbackMediaUri': fallbackMediaUri,
            if (clearBeforeWrite) 'clearBeforeWrite': true,
          },
        );
        if (!success) {
          throw StateError('Metadata update failed.');
        }
      },
      failureMessage: 'Metadata update failed',
      errorLogPrefix: '[AudioCore][Metadata] updateMetadata',
    );
  }

  Future<List<bool>> updateMetadataBatch({
    required List<TrackMetadataWriteRequest> requests,
  }) async {
    if (requests.isEmpty) {
      return const <bool>[];
    }

    final normalizedRequests = <_IndexedWriteRequest>[];
    final results = List<bool>.filled(requests.length, false, growable: false);

    for (var i = 0; i < requests.length; i++) {
      final request = requests[i];
      final path = request.path.trim();
      if (path.isEmpty) {
        continue;
      }

      normalizedRequests.add(
        _IndexedWriteRequest(
          index: i,
          request: TrackMetadataWriteRequest(
            path: path,
            metadata: request.metadata,
            clearBeforeWrite: request.clearBeforeWrite,
            fallbackMediaUri: request.fallbackMediaUri,
          ),
        ),
      );
    }

    if (normalizedRequests.isEmpty) {
      return results;
    }

    final unoccupiedRequests = <TrackMetadataWriteRequest>[];
    final unoccupiedIndexes = <int>[];

    for (final entry in normalizedRequests) {
      final request = entry.request;
      final file = request.path.startsWith('content://')
          ? null
          : File(request.path);
      if (file != null && await _isFileOccupied(request.path)) {
        taglib.TagLibFile.lastError = 'file_occupied';
        debugPrint(
          '[AudioCore][Metadata] File occupied by another app: ${request.path}',
        );
        results[entry.index] = false;
        continue;
      }

      unoccupiedRequests.add(request);
      unoccupiedIndexes.add(entry.index);
    }

    if (unoccupiedRequests.isEmpty) {
      return results;
    }

    final needsSync = unoccupiedRequests.any((request) {
      return _needsMetadataWriteSyncForPath(request.path);
    });
    return _runBatchWriteOperation(
      needsSync: needsSync,
      operation: () => _metadataService.updateTrackMetadataBatch(
        requests: unoccupiedRequests,
      ),
      results: results,
      unoccupiedIndexes: unoccupiedIndexes,
      failureMessage: 'Metadata batch update failed',
      errorLogPrefix: '[AudioCore][Metadata] updateMetadataBatch',
    );
  }

  Future<List<bool>> copyMetadataBatch({
    required List<TrackMetadataCopyRequest> requests,
  }) async {
    if (requests.isEmpty) {
      return const <bool>[];
    }

    final results = List<bool>.filled(requests.length, false, growable: false);
    final unoccupiedRequests = <TrackMetadataCopyRequest>[];
    final unoccupiedIndexes = <int>[];

    for (var i = 0; i < requests.length; i++) {
      final request = requests[i];
      final targetPath = request.targetPath.trim();
      final file = targetPath.startsWith('content://')
          ? null
          : File(targetPath);
      if (file != null && await _isFileOccupied(targetPath)) {
        taglib.TagLibFile.lastError = 'file_occupied';
        debugPrint(
          '[AudioCore][Metadata] Target file occupied by another app: $targetPath',
        );
        results[i] = false;
        continue;
      }

      unoccupiedRequests.add(
        TrackMetadataCopyRequest(
          sourcePath: request.sourcePath.trim(),
          targetPath: targetPath,
        ),
      );
      unoccupiedIndexes.add(i);
    }

    if (unoccupiedRequests.isEmpty) {
      return results;
    }

    final needsSync = unoccupiedRequests.any((request) {
      return _needsMetadataWriteSyncForPath(request.targetPath.trim());
    });
    return _runBatchWriteOperation(
      needsSync: needsSync,
      operation: () =>
          _metadataService.copyTrackMetadataBatch(requests: unoccupiedRequests),
      results: results,
      unoccupiedIndexes: unoccupiedIndexes,
      failureMessage: 'Metadata batch copy failed',
      errorLogPrefix: '[AudioCore][Metadata] copyMetadataBatch',
    );
  }

  Future<bool> _runWriteOperation({
    required bool needsSync,
    required Future<void> Function() operation,
    required String failureMessage,
    required String errorLogPrefix,
  }) async {
    var preparedForWrite = false;
    try {
      if (needsSync) {
        await _fileAccess.prepareForFileWrite();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        preparedForWrite = true;
      }

      await operation();
      _notifyListeners();
      return true;
    } catch (e) {
      _handleError(
        e,
        failureMessage: failureMessage,
        errorLogPrefix: errorLogPrefix,
      );
      return false;
    } finally {
      if (preparedForWrite) {
        await _fileAccess.finishFileWrite().catchError((_) {});
      }
    }
  }

  Future<List<bool>> _runBatchWriteOperation({
    required bool needsSync,
    required Future<List<bool>> Function() operation,
    required List<bool> results,
    required List<int> unoccupiedIndexes,
    required String failureMessage,
    required String errorLogPrefix,
  }) async {
    var preparedForWrite = false;
    try {
      if (needsSync) {
        await _fileAccess.prepareForFileWrite();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        preparedForWrite = true;
      }

      final operationResults = await operation();
      for (var i = 0; i < unoccupiedIndexes.length; i++) {
        results[unoccupiedIndexes[i]] = operationResults[i];
      }
      _notifyListeners();
      return results;
    } catch (e) {
      _handleError(
        e,
        failureMessage: failureMessage,
        errorLogPrefix: errorLogPrefix,
      );
      return results;
    } finally {
      if (preparedForWrite) {
        await _fileAccess.finishFileWrite().catchError((_) {});
      }
    }
  }

  void _handleError(
    Object error, {
    required String failureMessage,
    required String errorLogPrefix,
  }) {
    final errorText = error is PlatformException
        ? [
            if (error.code.isNotEmpty) error.code,
            if (error.message != null && error.message!.isNotEmpty)
              error.message!,
            if (error.details != null) 'details: ${error.details}',
          ].join(' | ')
        : error.toString();

    debugPrint('$errorLogPrefix failed: $errorText');
    _reportError('$failureMessage: $errorText');
  }

  Future<bool> _isFileOccupied(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        return false;
      }

      final access = await file.open(mode: FileMode.append);
      await access.close();
      return false;
    } catch (e) {
      if (e is FileSystemException) {
        final code = e.osError?.errorCode;
        if (Platform.isWindows) {
          if (code == 32 || code == 33) {
            return true;
          }
        } else {
          if (code == 11 || code == 26 || code == 32 || code == 33) {
            return true;
          }
        }
      }
      return false;
    }
  }

  bool _needsMetadataWriteSyncForPath(String path) {
    final current = _currentPlaybackPath();
    if (current == null) {
      return false;
    }

    final normCurrent = _normalizeLocalPathKey(current);
    final normPath = _normalizeLocalPathKey(path);
    if (normCurrent == null || normPath == null) {
      return current == path;
    }
    return normCurrent == normPath;
  }

  String? _normalizeLocalPath(String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty || trimmed.contains('://')) {
      return null;
    }
    return File(trimmed).absolute.path;
  }

  String? _normalizeLocalPathKey(String path) {
    final normalized = _normalizeLocalPath(path);
    if (normalized == null) {
      return null;
    }
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }
}

final class _IndexedWriteRequest {
  const _IndexedWriteRequest({required this.index, required this.request});

  final int index;
  final TrackMetadataWriteRequest request;
}
