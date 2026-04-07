import 'dart:async';
import 'dart:typed_data';
import '../rust/api/simple_api.dart' as rust;
import '../rust/api/simple/equalizer.dart';
import '../player_models.dart';
import 'audio_engine_interface.dart';

class RustAudioEngine implements AudioEngine {
  final _statusController = StreamController<AudioStatus>.broadcast();
  StreamSubscription? _subscription;

  @override
  Stream<AudioStatus> get statusStream => _statusController.stream;

  @override
  Future<void> initialize() async {
    _subscription = rust.subscribePlaybackState().listen((state) {
      _statusController.add(
        AudioStatus(
          path: state.path,
          position: Duration(milliseconds: state.positionMs.toInt()),
          duration: Duration(milliseconds: state.durationMs.toInt()),
          isPlaying: state.isPlaying,
          volume: state.volume,
          error: state.error,
        ),
      );
    });
  }

  @override
  Future<void> dispose() async {
    await _subscription?.cancel();
    await _statusController.close();
    await rust.disposeAudio();
  }

  @override
  Future<void> load(String path) => rust.loadAudioFile(path: path);

  @override
  Future<void> crossfade(String path, Duration duration) => rust
      .crossfadeToAudioFile(path: path, durationMs: duration.inMilliseconds);

  @override
  Future<void> play({Duration? fadeDuration}) =>
      rust.playAudio(fadeDurationMs: fadeDuration?.inMilliseconds ?? 0);

  @override
  Future<void> pause({Duration? fadeDuration}) =>
      rust.pauseAudio(fadeDurationMs: fadeDuration?.inMilliseconds ?? 0);

  @override
  Future<void> seek(Duration position) =>
      rust.seekAudioMs(positionMs: position.inMilliseconds);

  @override
  Future<void> setVolume(double volume) => rust.setAudioVolume(volume: volume);

  @override
  Future<Duration> getDuration() async {
    final ms = await rust.getAudioDurationMs();
    return Duration(milliseconds: ms.toInt());
  }

  @override
  Future<Duration> getCurrentPosition() async {
    final ms = await rust.getAudioPositionMs();
    return Duration(milliseconds: ms.toInt());
  }

  @override
  Future<List<double>> getLatestFft() async {
    final data = await rust.getLatestFft();
    return data.map((e) => e.toDouble()).toList();
  }

  @override
  Future<List<double>> getWaveform({
    required String path,
    required int expectedChunks,
    int sampleStride = 1,
  }) async {
    final data = await rust.extractWaveformForPath(
      path: path,
      expectedChunks: BigInt.from(expectedChunks),
      sampleStride: BigInt.from(sampleStride),
    );
    return data.toList();
  }

  @override
  Future<void> setEqualizerConfig(EqualizerConfig config) =>
      rust.setAudioEqualizerConfig(config: config);

  @override
  Future<EqualizerConfig> getEqualizerConfig() =>
      rust.getAudioEqualizerConfig();

  @override
  bool get supportsCrossfade => true;

  @override
  Future<void> setFadeSettings(FadeSettings settings) async {}

  @override
  Future<String?> extractFingerprint(String path) async {
    try {
      return await rust.getAudioFingerprint(path: path);
    } catch (e) {
      return null;
    }
  }

  @override
  Future<void> prepareForFileWrite() => rust.prepareForFileWrite();

  @override
  Future<void> finishFileWrite() => rust.finishFileWrite();

  @override
  Future<bool> updateTrackMetadata({
    required String path,
    required Map<String, Object?> metadata,
  }) async {
    await rust.updateTrackMetadata(
      path: path,
      metadata: _trackMetadataUpdateFromMap(metadata),
    );
    return true;
  }

  @override
  Future<void> removeAllTags({String? path}) async {
    final targetPath = path?.trim();
    if (targetPath == null || targetPath.isEmpty) {
      throw ArgumentError.value(path, 'path', 'Path is required here.');
    }
    await rust.removeAllTags(path: targetPath);
  }

  rust.TrackMetadataUpdate _trackMetadataUpdateFromMap(
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

  List<String> _asStringList(Object? value) {
    if (value is! List) return const <String>[];
    return value
        .whereType<Object?>()
        .map(_asString)
        .whereType<String>()
        .toList(growable: false);
  }

  String? _asString(Object? value) {
    if (value is String) {
      final trimmed = value.trim();
      return trimmed.isEmpty ? null : value;
    }
    return null;
  }

  int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return null;
  }
}
