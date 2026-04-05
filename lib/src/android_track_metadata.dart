import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart' as amr;
import 'package:audio_metadata_reader/audio_metadata_reader.dart'
    show ParserTag;

T? _firstOrNull<T>(Iterable<T> values) {
  final iterator = values.iterator;
  if (!iterator.moveNext()) return null;
  return iterator.current;
}

class AndroidTrackPicture {
  const AndroidTrackPicture({
    required this.bytes,
    required this.mimeType,
    this.pictureType = 'Front Cover',
    this.description,
  });

  final Uint8List bytes;
  final String mimeType;
  final String pictureType;
  final String? description;

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'bytes': bytes,
      'mimeType': mimeType,
      'pictureType': pictureType,
      if (description != null) 'description': description,
    };
  }
}

class AndroidTrackMetadataUpdate {
  const AndroidTrackMetadataUpdate({
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
    this.genres = const <String>[],
    this.pictures = const <AndroidTrackPicture>[],
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
  final List<String> genres;
  final List<AndroidTrackPicture> pictures;

  Map<String, Object?> toMap() {
    return <String, Object?>{
      if (title != null) 'title': title,
      if (artist != null) 'artist': artist,
      if (album != null) 'album': album,
      if (albumArtist != null) 'albumArtist': albumArtist,
      if (trackNumber != null) 'trackNumber': trackNumber,
      if (trackTotal != null) 'trackTotal': trackTotal,
      if (discNumber != null) 'discNumber': discNumber,
      if (date != null) 'date': date,
      if (year != null) 'year': year,
      if (comment != null) 'comment': comment,
      if (lyrics != null) 'lyrics': lyrics,
      if (composer != null) 'composer': composer,
      if (lyricist != null) 'lyricist': lyricist,
      if (performer != null) 'performer': performer,
      if (conductor != null) 'conductor': conductor,
      if (remixer != null) 'remixer': remixer,
      if (genres.isNotEmpty) 'genres': genres,
      if (pictures.isNotEmpty)
        'pictures': pictures.map((picture) => picture.toMap()).toList(),
    };
  }

  factory AndroidTrackMetadataUpdate.fromParserTag(ParserTag metadata) {
    switch (metadata) {
      case amr.Mp3Metadata m:
        return AndroidTrackMetadataUpdate(
          title: m.songName,
          artist: m.leadPerformer,
          album: m.album,
          albumArtist: m.bandOrOrchestra,
          trackNumber: m.trackNumber,
          trackTotal: m.trackTotal,
          year: m.year,
          composer: m.composer,
          lyrics: m.lyric,
          genres: List<String>.from(m.genres),
          pictures: m.pictures
              .map(
                (picture) => AndroidTrackPicture(
                  bytes: picture.bytes,
                  mimeType: picture.mimetype,
                  pictureType: _pictureTypeToAndroidLabel(picture.pictureType),
                ),
              )
              .toList(),
        );
      case amr.Mp4Metadata m:
        return AndroidTrackMetadataUpdate(
          title: m.title,
          artist: m.artist,
          album: m.album,
          discNumber: m.discNumber,
          trackNumber: m.trackNumber,
          date: m.year?.toIso8601String().substring(0, 10),
          trackTotal: m.totalTracks,
          year: m.year?.year,
          lyrics: m.lyrics,
          genres: m.genre == null ? const <String>[] : <String>[m.genre!],
          pictures: m.picture == null
              ? const <AndroidTrackPicture>[]
              : <AndroidTrackPicture>[
                  AndroidTrackPicture(
                    bytes: m.picture!.bytes,
                    mimeType: m.picture!.mimetype,
                    pictureType: _pictureTypeToAndroidLabel(
                      m.picture!.pictureType,
                    ),
                  ),
                ],
        );
      case amr.VorbisMetadata m:
        return AndroidTrackMetadataUpdate(
          title: _firstOrNull(m.title),
          artist: _firstOrNull(m.artist),
          album: _firstOrNull(m.album),
          albumArtist: _firstOrNull(m.performer),
          trackNumber: _firstOrNull(m.trackNumber),
          trackTotal: m.trackTotal,
          discNumber: m.discNumber,
          date: _firstOrNull(m.date)?.toIso8601String().substring(0, 10),
          year: _firstOrNull(m.date)?.year,
          comment: _firstOrNull(m.comment),
          lyrics: m.lyric,
          composer: _firstOrNull(m.composer),
          lyricist: _firstOrNull(m.description),
          genres: List<String>.from(m.genres),
          pictures: m.pictures
              .map(
                (picture) => AndroidTrackPicture(
                  bytes: picture.bytes,
                  mimeType: picture.mimetype,
                  pictureType: _pictureTypeToAndroidLabel(picture.pictureType),
                ),
              )
              .toList(),
        );
      case amr.RiffMetadata m:
        return AndroidTrackMetadataUpdate(
          title: m.title,
          artist: m.artist,
          album: m.album,
          comment: m.comment,
          trackNumber: m.trackNumber,
          year: m.year?.year,
          lyrics: m.comment,
          genres: m.genre == null ? const <String>[] : <String>[m.genre!],
          pictures: m.pictures
              .map(
                (picture) => AndroidTrackPicture(
                  bytes: picture.bytes,
                  mimeType: picture.mimetype,
                  pictureType: _pictureTypeToAndroidLabel(picture.pictureType),
                ),
              )
              .toList(),
        );
    }
  }

  static String _pictureTypeToAndroidLabel(amr.PictureType type) {
    switch (type) {
      case amr.PictureType.coverFront:
        return 'Front Cover';
      case amr.PictureType.coverBack:
        return 'Back Cover';
      case amr.PictureType.leafletPage:
        return 'Leaflet Page';
      case amr.PictureType.mediaLabelCD:
        return 'Media Label CD';
      case amr.PictureType.artistPerformer:
        return 'Artist / Performer';
      case amr.PictureType.bandArtistLogotype:
        return 'Band Logo';
      default:
        return 'Other';
    }
  }
}
