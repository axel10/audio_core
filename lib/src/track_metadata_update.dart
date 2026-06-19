import 'dart:typed_data';

import 'android_metadata_models.dart';
import 'track_metadata.dart';

T? _firstOrNull<T>(Iterable<T> values) {
  final iterator = values.iterator;
  if (!iterator.moveNext()) return null;
  return iterator.current;
}

class TrackMetadataPicture {
  const TrackMetadataPicture({
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

class TrackMetadataUpdate {
  const TrackMetadataUpdate({
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
    this.pictures = const <TrackMetadataPicture>[],
    this.clearArtwork,
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
  final List<TrackMetadataPicture> pictures;
  final bool? clearArtwork;

  Map<String, Object?> toMap({bool includeEmptyCollections = false}) {
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
      if (includeEmptyCollections || genres.isNotEmpty) 'genres': genres,
      if (clearArtwork == true)
        'pictures': const <Object?>[]
      else if (includeEmptyCollections || pictures.isNotEmpty)
        'pictures': pictures.map((picture) => picture.toMap()).toList(),
    };
  }

  void applyTo(ParserTag metadata) {
    if (title != null) metadata.setTitle(title);
    if (artist != null) metadata.setArtist(artist);
    if (album != null) metadata.setAlbum(album);
    if (trackNumber != null) metadata.setTrackNumber(trackNumber);
    if (trackTotal != null) metadata.setTrackTotal(trackTotal);
    if (discNumber != null) metadata.setCD(discNumber, null);

    final resolvedDate = _resolveDateTime();
    if (resolvedDate != null) {
      metadata.setYear(resolvedDate);
    }
    if (clearArtwork == true) {
      metadata.setPictures(const <Picture>[]);
    } else if (pictures.isNotEmpty) {
      metadata.setPictures(
        pictures
            .map(
              (picture) => Picture(
                picture.bytes,
                picture.mimeType,
                _androidLabelToPictureType(picture.pictureType),
              ),
            )
            .toList(),
      );
    }

    switch (metadata) {
      case Mp3Metadata m:
        if (albumArtist != null) m.bandOrOrchestra = albumArtist;
        if (lyrics != null) m.lyric = lyrics;
        if (composer != null) m.composer = composer;
        if (lyricist != null) m.textWriter = lyricist;
        if (performer != null) m.leadPerformer = performer;
        if (conductor != null) m.conductor = conductor;
        if (genres.isNotEmpty) m.genres = List<String>.from(genres);
        break;
      case Mp4Metadata m:
        if (lyrics != null) m.lyrics = lyrics;
        if (genres.isNotEmpty) {
          m.genre = genres.first;
        }
        break;
      case VorbisMetadata m:
        if (albumArtist != null && performer == null) {
          m.performer = [albumArtist!];
        }
        if (comment != null) m.comment = [comment!];
        if (lyrics != null) m.lyric = lyrics;
        if (composer != null) m.composer = [composer!];
        if (lyricist != null) m.description = [lyricist!];
        if (performer != null) m.performer = [performer!];
        if (genres.isNotEmpty) m.genres = List<String>.from(genres);
        break;
      case RiffMetadata m:
        if (comment != null) m.comment = comment;
        if (lyrics != null) m.comment = lyrics;
        if (composer != null) m.encoder = composer;
        if (genres.isNotEmpty) m.genre = genres.first;
        break;
    }
  }

  DateTime? _resolveDateTime() {
    if (date != null && date!.trim().isNotEmpty) {
      final parsed = DateTime.tryParse(date!);
      if (parsed != null) return parsed;
    }
    if (year != null) {
      return DateTime(year!);
    }
    return null;
  }

  factory TrackMetadataUpdate.fromParserTag(ParserTag metadata) {
    switch (metadata) {
      case Mp3Metadata m:
        return TrackMetadataUpdate(
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
                (picture) => TrackMetadataPicture(
                  bytes: picture.bytes,
                  mimeType: picture.mimetype,
                  pictureType: _pictureTypeToAndroidLabel(picture.pictureType),
                ),
              )
              .toList(),
        );
      case Mp4Metadata m:
        return TrackMetadataUpdate(
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
              ? const <TrackMetadataPicture>[]
              : <TrackMetadataPicture>[
                  TrackMetadataPicture(
                    bytes: m.picture!.bytes,
                    mimeType: m.picture!.mimetype,
                    pictureType: _pictureTypeToAndroidLabel(
                      m.picture!.pictureType,
                    ),
                  ),
                ],
        );
      case VorbisMetadata m:
        return TrackMetadataUpdate(
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
                (picture) => TrackMetadataPicture(
                  bytes: picture.bytes,
                  mimeType: picture.mimetype,
                  pictureType: _pictureTypeToAndroidLabel(picture.pictureType),
                ),
              )
              .toList(),
        );
      case RiffMetadata m:
        return TrackMetadataUpdate(
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
                (picture) => TrackMetadataPicture(
                  bytes: picture.bytes,
                  mimeType: picture.mimetype,
                  pictureType: _pictureTypeToAndroidLabel(picture.pictureType),
                ),
              )
              .toList(),
        );
    }
  }

  factory TrackMetadataUpdate.fromTrackMetadata(TrackMetadata metadata) {
    return TrackMetadataUpdate(
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
      genres: List<String>.from(metadata.genres),
      pictures: metadata.pictures
          .map(
            (picture) => TrackMetadataPicture(
              bytes: picture.bytes,
              mimeType: picture.mimeType,
              pictureType: picture.pictureType,
              description: picture.description,
            ),
          )
          .toList(growable: false),
    );
  }

  static String _pictureTypeToAndroidLabel(PictureType type) {
    switch (type) {
      case PictureType.coverFront:
        return 'Front Cover';
      case PictureType.coverBack:
        return 'Back Cover';
      case PictureType.leafletPage:
        return 'Leaflet Page';
      case PictureType.mediaLabelCD:
        return 'Media Label CD';
      case PictureType.artistPerformer:
        return 'Artist / Performer';
      case PictureType.bandArtistLogotype:
        return 'Band Logo';
      default:
        return 'Other';
    }
  }

  static PictureType _androidLabelToPictureType(String type) {
    switch (type) {
      case 'Front Cover':
        return PictureType.coverFront;
      case 'Back Cover':
        return PictureType.coverBack;
      case 'Leaflet Page':
        return PictureType.leafletPage;
      case 'Media Label CD':
        return PictureType.mediaLabelCD;
      case 'Artist / Performer':
        return PictureType.artistPerformer;
      case 'Band Logo':
        return PictureType.bandArtistLogotype;
      default:
        return PictureType.other;
    }
  }
}

/// A batch item for copying one track's embedded metadata to another track.
class TrackMetadataCopyRequest {
  const TrackMetadataCopyRequest({
    required this.sourcePath,
    required this.targetPath,
  });

  /// File path or content URI for the source track.
  final String sourcePath;

  /// File path or content URI for the target track.
  final String targetPath;

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'sourcePath': sourcePath,
      'targetPath': targetPath,
    };
  }
}

/// A single metadata write request for a target track.
class TrackMetadataWriteRequest {
  const TrackMetadataWriteRequest({
    required this.path,
    required this.metadata,
    this.clearBeforeWrite = false,
    this.fallbackMediaUri,
  });

  final String path;
  final TrackMetadataUpdate metadata;
  final bool clearBeforeWrite;
  final String? fallbackMediaUri;

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'path': path,
      'metadata': metadata.toMap(includeEmptyCollections: clearBeforeWrite),
      if (fallbackMediaUri != null && fallbackMediaUri!.trim().isNotEmpty)
        'fallbackMediaUri': fallbackMediaUri!.trim(),
      if (clearBeforeWrite) 'clearBeforeWrite': true,
    };
  }
}
