import 'dart:typed_data';

import '../rust/api/simple/metadata.dart' as rust;
import '../track_metadata.dart';
import '../track_metadata_update.dart';

rust.TrackMetadataUpdate trackMetadataUpdateFromMap(
  Map<String, Object?> metadata,
) {
  return rust.TrackMetadataUpdate(
    title: _asString(metadata['title']),
    artist: _asString(metadata['artist']),
    album: _asString(metadata['album']),
    albumArtist: _asString(metadata['albumArtist']),
    trackNumber: _asInt(metadata['trackNumber']),
    trackTotal: _asInt(metadata['trackTotal']),
    discNumber: _asInt(metadata['discNumber']),
    date: _asString(metadata['date']),
    year: _asInt(metadata['year']),
    comment: _asString(metadata['comment']),
    lyrics: _asString(metadata['lyrics']),
    composer: _asString(metadata['composer']),
    lyricist: _asString(metadata['lyricist']),
    performer: _asString(metadata['performer']),
    conductor: _asString(metadata['conductor']),
    remixer: _asString(metadata['remixer']),
    genres: _asStringList(metadata['genres']),
    pictures: _asPictureList(metadata['pictures']),
  );
}

rust.TrackMetadataUpdate trackMetadataUpdateFromUpdate(
  TrackMetadataUpdate metadata, {
  bool includeEmptyCollections = false,
}) {
  return trackMetadataUpdateFromMap(
    metadata.toMap(includeEmptyCollections: includeEmptyCollections),
  );
}

TrackMetadata trackMetadataFromRust(
  rust.TrackMetadataUpdate metadata, {
  Map<String, Object?> raw = const <String, Object?>{},
  String? metadataType,
  String? error,
}) {
  return TrackMetadata.fromRust(
    metadata,
    raw: raw,
    metadataType: metadataType,
    error: error,
  );
}

List<String> _asStringList(Object? value) {
  if (value is! List) return const <String>[];
  return value
      .whereType<Object?>()
      .map(_asString)
      .whereType<String>()
      .toList(growable: false);
}

List<rust.TrackPicture> _asPictureList(Object? value) {
  if (value is! List) return const <rust.TrackPicture>[];

  final pictures = <rust.TrackPicture>[];
  for (final entry in value) {
    if (entry is Map<Object?, Object?>) {
      pictures.add(_asPicture(entry.cast<String, Object?>()));
    } else if (entry is Map) {
      pictures.add(_asPicture(entry.cast<String, Object?>()));
    }
  }
  return pictures;
}

rust.TrackPicture _asPicture(Map<String, Object?> map) {
  final bytes = map['bytes'];
  return rust.TrackPicture(
    bytes: bytes is Uint8List
        ? bytes
        : bytes is List<int>
        ? Uint8List.fromList(bytes)
        : Uint8List(0),
    mimeType: _asString(map['mimeType']) ?? 'image/jpeg',
    pictureType: _asString(map['pictureType']) ?? 'Other',
    description: _asString(map['description']),
  );
}

String? _asString(Object? value) {
  if (value is String) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
  return null;
}

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return null;
}
