import 'dart:typed_data';

import 'rust/api/simple/metadata.dart' as rust;

class TrackMetadata {
  const TrackMetadata({
    this.title,
    this.artist,
    this.album,
    this.albumArtist,
    this.trackNumber,
    this.trackTotal,
    this.discNumber,
    this.date,
    this.year,
    this.comment,
    this.lyrics,
    this.composer,
    this.lyricist,
    this.performer,
    this.conductor,
    this.remixer,
    this.metadataType,
    this.error,
    this.raw = const <String, Object?>{},
    required this.genres,
    required this.pictures,
  });

  final String? title;
  final String? artist;
  final String? album;
  final String? albumArtist;
  final int? trackNumber;
  final int? trackTotal;
  final int? discNumber;
  final String? date;
  final int? year;
  final String? comment;
  final String? lyrics;
  final String? composer;
  final String? lyricist;
  final String? performer;
  final String? conductor;
  final String? remixer;
  final String? metadataType;
  final String? error;
  final Map<String, Object?> raw;
  final List<String> genres;
  final List<rust.TrackPicture> pictures;

  factory TrackMetadata.fromMap(Map<String, Object?> map) {
    return TrackMetadata(
      title: _asString(map['title']),
      artist: _asString(map['artist']),
      album: _asString(map['album']),
      albumArtist: _asString(map['albumArtist']),
      trackNumber: _asInt(map['trackNumber']),
      trackTotal: _asInt(map['trackTotal']),
      discNumber: _asInt(map['discNumber']),
      date: _asString(map['date']),
      year: _asInt(map['year']),
      comment: _asString(map['comment']),
      lyrics: _asString(map['lyrics']),
      composer: _asString(map['composer']),
      lyricist: _asString(map['lyricist']),
      performer: _asString(map['performer']),
      conductor: _asString(map['conductor']),
      remixer: _asString(map['remixer']),
      metadataType: _asString(map['metadataType']),
      error: _asString(map['_error']) ?? _asString(map['error']),
      genres: _asStringList(map['genres']),
      pictures: _asPictureList(map['pictures']),
      raw: Map<String, Object?>.from(map),
    );
  }

  factory TrackMetadata.fromRust(
    rust.TrackMetadataUpdate metadata, {
    Map<String, Object?> raw = const <String, Object?>{},
    String? metadataType,
    String? error,
  }) {
    return TrackMetadata(
      title: metadata.title,
      artist: metadata.artist,
      album: metadata.album,
      albumArtist: metadata.albumArtist,
      trackNumber: metadata.trackNumber,
      trackTotal: metadata.trackTotal,
      discNumber: metadata.discNumber,
      date: metadata.date,
      year: metadata.year,
      comment: metadata.comment,
      lyrics: metadata.lyrics,
      composer: metadata.composer,
      lyricist: metadata.lyricist,
      performer: metadata.performer,
      conductor: metadata.conductor,
      remixer: metadata.remixer,
      metadataType: metadataType,
      error: error,
      raw: raw,
      genres: List<String>.from(metadata.genres),
      pictures: List<rust.TrackPicture>.from(metadata.pictures),
    );
  }

  TrackMetadata copyWith({
    String? title,
    String? artist,
    String? album,
    String? albumArtist,
    int? trackNumber,
    int? trackTotal,
    int? discNumber,
    String? date,
    int? year,
    String? comment,
    String? lyrics,
    String? composer,
    String? lyricist,
    String? performer,
    String? conductor,
    String? remixer,
    String? metadataType,
    String? error,
    Map<String, Object?>? raw,
    List<String>? genres,
    List<rust.TrackPicture>? pictures,
  }) {
    return TrackMetadata(
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      albumArtist: albumArtist ?? this.albumArtist,
      trackNumber: trackNumber ?? this.trackNumber,
      trackTotal: trackTotal ?? this.trackTotal,
      discNumber: discNumber ?? this.discNumber,
      date: date ?? this.date,
      year: year ?? this.year,
      comment: comment ?? this.comment,
      lyrics: lyrics ?? this.lyrics,
      composer: composer ?? this.composer,
      lyricist: lyricist ?? this.lyricist,
      performer: performer ?? this.performer,
      conductor: conductor ?? this.conductor,
      remixer: remixer ?? this.remixer,
      metadataType: metadataType ?? this.metadataType,
      error: error ?? this.error,
      raw: raw ?? this.raw,
      genres: genres ?? this.genres,
      pictures: pictures ?? this.pictures,
    );
  }

  bool get hasError => error?.trim().isNotEmpty == true;

  static String? _asString(Object? value) {
    if (value is String) {
      final trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
    }
    return null;
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return null;
  }

  static List<String> _asStringList(Object? value) {
    if (value is! List) return const <String>[];
    return value
        .map((item) => item?.toString().trim())
        .whereType<String>()
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }

  static List<rust.TrackPicture> _asPictureList(Object? value) {
    if (value is! List) return const <rust.TrackPicture>[];

    final pictures = <rust.TrackPicture>[];
    for (final entry in value) {
      if (entry is rust.TrackPicture) {
        pictures.add(entry);
        continue;
      }
      if (entry is Map<Object?, Object?>) {
        pictures.add(_asPicture(entry.cast<String, Object?>()));
      } else if (entry is Map) {
        pictures.add(_asPicture(entry.cast<String, Object?>()));
      }
    }
    return pictures;
  }

  static rust.TrackPicture _asPicture(Map<String, Object?> map) {
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
}
