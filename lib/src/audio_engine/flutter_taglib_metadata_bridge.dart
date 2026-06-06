import 'package:flutter/foundation.dart';
import 'package:flutter_taglib/flutter_taglib.dart' as taglib;

import '../rust/api/simple/metadata.dart' as rust;
import '../track_metadata.dart';
import '../track_metadata_update.dart';

const String _metadataTypeFlutterTaglib = 'flutter_taglib';

Future<TrackMetadata?> readTrackMetadataWithFlutterTaglib(
  String path, {
  String? fallbackMediaUri,
}) async {
  if (!taglib.TagLibFile.isSupported) {
    return null;
  }

  for (final candidate in _metadataPathCandidates(path, fallbackMediaUri)) {
    final file = await taglib.TagLibFile.openAsync(candidate);
    if (file == null) {
      continue;
    }

    try {
      final properties = file.properties;
      final pictures = file.pictures;

      final date = _firstString(properties, taglib.TagProperties.date);
      final year = _readYear(properties, date);
      final trackNumber = _readTrackNumber(properties);
      final trackTotal = _readInt(properties, taglib.TagProperties.trackTotal);
      final discNumber = _readInt(properties, taglib.TagProperties.discNumber);
      final duration = file.duration;
      final raw = <String, Object?>{
        ...properties,
        'hasCover': file.hasCover,
        if (file.coverMimeType != null) 'coverMimeType': file.coverMimeType,
        'durationMs': duration.inMilliseconds,
      };

      return TrackMetadata(
        title: _stringOrNull(file.title),
        artist: _stringOrNull(file.artist),
        album: _stringOrNull(file.album),
        albumArtist: _firstString(properties, taglib.TagProperties.albumArtist),
        trackNumber: trackNumber,
        trackTotal: trackTotal,
        discNumber: discNumber,
        date: date,
        year: year,
        duration: duration,
        comment:
            _stringOrNull(file.comment) ??
            _firstString(properties, taglib.TagProperties.comment),
        lyrics: _firstString(properties, taglib.TagProperties.lyrics),
        composer: _firstString(properties, taglib.TagProperties.composer),
        lyricist: _firstString(properties, 'LYRICIST'),
        performer: _firstString(properties, taglib.TagProperties.performer),
        conductor: _firstString(properties, taglib.TagProperties.conductor),
        remixer: _firstString(properties, taglib.TagProperties.remixer),
        metadataType: _metadataTypeFlutterTaglib,
        error: null,
        raw: raw,
        genres: List<String>.from(
          properties[taglib.TagProperties.genre] ?? const <String>[],
        ),
        pictures: pictures
            .map(
              (picture) => rust.TrackPicture(
                bytes: picture.bytes,
                mimeType: picture.mimeType,
                pictureType: picture.pictureType,
                description: picture.description,
              ),
            )
            .toList(growable: false),
      );
    } finally {
      file.close();
    }
  }

  return null;
}

Future<bool> updateTrackMetadataWithFlutterTaglib({
  required String path,
  required Map<String, Object?> metadata,
  String? fallbackMediaUri,
}) async {
  if (!taglib.TagLibFile.isSupported) {
    taglib.TagLibFile.lastError = 'TagLib is not supported on this platform';
    debugPrint('[flutter_taglib] ${taglib.TagLibFile.lastError}');
    return false;
  }

  final rawPictures = metadata['pictures'];
  final pictures = _asPictures(rawPictures);

  String? lastFailureReason;

  for (final candidate in _metadataPathCandidates(path, fallbackMediaUri)) {
    final file = await taglib.TagLibFile.openAsync(
      candidate,
      writeAccess: true,
    );
    if (file == null) {
      lastFailureReason = taglib.TagLibFile.lastError ?? 'Failed to open file $candidate';
      continue;
    }

    try {
      final clearBeforeWrite = metadata['clearBeforeWrite'] as bool? ?? false;
      final merged = <String, List<String>>{};
      if (!clearBeforeWrite) {
        merged.addAll(file.properties);
      }

      _putSingle(merged, taglib.TagProperties.title, metadata['title']);
      _putSingle(merged, taglib.TagProperties.artist, metadata['artist']);
      _putSingle(merged, taglib.TagProperties.album, metadata['album']);
      _putSingle(
        merged,
        taglib.TagProperties.albumArtist,
        metadata['albumArtist'],
      );

      if (metadata.containsKey('trackNumber')) {
        final trackNumber = _asInt(metadata['trackNumber']);
        if (trackNumber != null) {
          merged[taglib.TagProperties.trackNumber] = <String>[
            trackNumber.toString(),
          ];
        }
      }
      if (metadata.containsKey('trackTotal')) {
        final trackTotal = _asInt(metadata['trackTotal']);
        if (trackTotal != null) {
          merged[taglib.TagProperties.trackTotal] = <String>[
            trackTotal.toString(),
          ];
        }
      }
      if (metadata.containsKey('discNumber')) {
        final discNumber = _asInt(metadata['discNumber']);
        if (discNumber != null) {
          merged[taglib.TagProperties.discNumber] = <String>[
            discNumber.toString(),
          ];
        }
      }

      final date = _stringOrNull(metadata['date']);
      final year = _asInt(metadata['year']);
      if (date != null) {
        merged[taglib.TagProperties.date] = <String>[date];
        final derivedYear = _yearFromDate(date) ?? year;
        if (derivedYear != null) {
          merged[taglib.TagProperties.year] = <String>[derivedYear.toString()];
        }
      } else if (year != null) {
        merged[taglib.TagProperties.date] = <String>[year.toString()];
        merged[taglib.TagProperties.year] = <String>[year.toString()];
      }

      _putSingle(merged, taglib.TagProperties.comment, metadata['comment']);
      _putSingle(merged, taglib.TagProperties.lyrics, metadata['lyrics']);
      _putSingle(merged, taglib.TagProperties.composer, metadata['composer']);
      _putSingle(merged, 'LYRICIST', metadata['lyricist']);
      _putSingle(merged, taglib.TagProperties.performer, metadata['performer']);
      _putSingle(merged, taglib.TagProperties.conductor, metadata['conductor']);
      _putSingle(merged, taglib.TagProperties.remixer, metadata['remixer']);

      if (metadata.containsKey('genres')) {
        final genres = _asStringList(metadata['genres']);
        if (genres.isEmpty) {
          merged.remove(taglib.TagProperties.genre);
        } else {
          merged[taglib.TagProperties.genre] = genres;
        }
      }

      final unsupported = file.setProperties(merged);
      if (unsupported.isNotEmpty) {
        debugPrint(
          '[flutter_taglib] unsupported properties while writing $candidate: '
          '${unsupported.keys.toList(growable: false)}',
        );
      }

      if (metadata.containsKey('pictures')) {
        if (!file.setPictures(pictures)) {
          lastFailureReason = 'Failed to write pictures (setPictures returned false)';
          taglib.TagLibFile.lastError = lastFailureReason;
          continue;
        }
      }

      if (file.save()) {
        return true;
      } else {
        lastFailureReason = taglib.TagLibFile.lastError ?? 'Native file save failed';
      }
    } finally {
      file.close();
    }
  }

  taglib.TagLibFile.lastError = lastFailureReason ?? 'No file path candidates were successfully processed';
  debugPrint('[flutter_taglib] updateTrackMetadataWithFlutterTaglib failed: ${taglib.TagLibFile.lastError}');
  return false;
}

Future<List<bool>> updateTrackMetadataBatchWithFlutterTaglib({
  required List<TrackMetadataWriteRequest> requests,
}) async {
  final results = <bool>[];
  for (final request in requests) {
    try {
      final success = await updateTrackMetadataWithFlutterTaglib(
        path: request.path,
        metadata: request.metadata.toMap(
          includeEmptyCollections: request.clearBeforeWrite,
        ),
        fallbackMediaUri: request.fallbackMediaUri,
      );
      results.add(success);
    } catch (_) {
      results.add(false);
    }
  }
  return results;
}

Future<List<bool>> copyTrackMetadataBatchWithFlutterTaglib({
  required List<TrackMetadataCopyRequest> requests,
}) async {
  final results = <bool>[];
  for (final request in requests) {
    try {
      final metadata = await readTrackMetadataWithFlutterTaglib(
        request.sourcePath,
      );
      if (metadata == null) {
        results.add(false);
        continue;
      }

      final success = await updateTrackMetadataWithFlutterTaglib(
        path: request.targetPath,
        metadata: <String, Object?>{
          ...TrackMetadataUpdate.fromTrackMetadata(
            metadata,
          ).toMap(includeEmptyCollections: true),
          'clearBeforeWrite': true,
        },
      );
      results.add(success);
    } catch (_) {
      results.add(false);
    }
  }
  return results;
}

Future<bool> removeAllTagsWithFlutterTaglib(
  String path, {
  String? fallbackMediaUri,
}) async {
  if (!taglib.TagLibFile.isSupported) {
    return false;
  }

  for (final candidate in _metadataPathCandidates(path, fallbackMediaUri)) {
    final file = await taglib.TagLibFile.openAsync(
      candidate,
      writeAccess: true,
    );
    if (file == null) {
      continue;
    }

    try {
      file.setProperties(const <String, List<String>>{});
      file.setCover(data: null);
      if (file.save()) {
        return true;
      }
    } finally {
      file.close();
    }
  }

  return false;
}

List<taglib.Picture> _asPictures(Object? value) {
  if (value is! List) return const <taglib.Picture>[];

  final pictures = <taglib.Picture>[];
  for (final entry in value) {
    if (entry is Map<Object?, Object?>) {
      final picture = _asPicture(entry.cast<String, Object?>());
      if (picture != null) pictures.add(picture);
    } else if (entry is Map) {
      final picture = _asPicture(entry.cast<String, Object?>());
      if (picture != null) pictures.add(picture);
    }
  }
  return pictures;
}

taglib.Picture? _asPicture(Map<String, Object?> map) {
  final bytes = map['bytes'];
  final data = bytes is Uint8List
      ? bytes
      : bytes is List<int>
      ? Uint8List.fromList(bytes)
      : null;
  if (data == null || data.isEmpty) return null;

  return taglib.Picture(
    bytes: data,
    mimeType: _stringOrNull(map['mimeType']) ?? 'image/jpeg',
    pictureType: _normalizePictureType(_stringOrNull(map['pictureType'])),
    description: _stringOrNull(map['description']),
  );
}

void _putSingle(Map<String, List<String>> target, String key, Object? value) {
  final text = _stringOrNull(value);
  if (text == null) return;
  target[key] = <String>[text];
}

String? _firstString(Map<String, List<String>> properties, String key) {
  final value = properties[key]?.firstOrNull;
  return _stringOrNull(value);
}

int? _readInt(Map<String, List<String>> properties, String key) {
  return _stringOrNull(properties[key]?.firstOrNull)?.toIntOrNull();
}

int? _readYear(Map<String, List<String>> properties, String? date) {
  final year = _readInt(properties, taglib.TagProperties.year);
  if (year != null) return year;
  return _yearFromDate(date);
}

int? _readTrackNumber(Map<String, List<String>> properties) {
  final trackNumberValue =
      properties[taglib.TagProperties.trackNumber]?.firstOrNull;
  final trackNumber = _stringOrNull(trackNumberValue);
  if (trackNumber == null) return null;

  final parts = trackNumber.split('/');
  return parts.firstOrNull?.trim().toIntOrNull();
}

int? _yearFromDate(String? date) {
  if (date == null || date.trim().isEmpty) return null;
  final cleaned = date.trim();
  final yearText = cleaned.length >= 4 ? cleaned.substring(0, 4) : cleaned;
  return yearText.toIntOrNull();
}

String _normalizePictureType(String? value) {
  final normalized = value?.trim();
  if (normalized == null || normalized.isEmpty) {
    return 'Front Cover';
  }
  return normalized;
}

String? _stringOrNull(Object? value) {
  final text = value?.toString().trim();
  if (text == null || text.isEmpty) return null;
  return text;
}

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return value?.toString().trim().toIntOrNull();
}

List<String> _asStringList(Object? value) {
  if (value is! List) return const <String>[];
  return value
      .map((entry) => _stringOrNull(entry))
      .whereType<String>()
      .toList(growable: false);
}

Iterable<String> _metadataPathCandidates(
  String path, [
  String? fallbackMediaUri,
]) sync* {
  final primary = path.trim();
  if (primary.isNotEmpty) {
    yield primary;
  }

  final fallback = fallbackMediaUri?.trim();
  if (fallback != null && fallback.isNotEmpty && fallback != primary) {
    yield fallback;
  }
}

extension on String {
  int? toIntOrNull() => int.tryParse(this);
}

extension on Iterable<String> {
  String? get firstOrNull {
    final iterator = this.iterator;
    if (!iterator.moveNext()) return null;
    return iterator.current;
  }
}
