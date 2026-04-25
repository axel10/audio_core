// import 'dart:typed_data';
//
// import 'package:audio_core/audio_core.dart';
// import 'package:audio_core/src/audio_engine/audio_engine_interface.dart';
// import 'package:audio_core/src/player_models.dart';
// import 'package:flutter_test/flutter_test.dart';
//
// void main() {
//   test(
//     'ignores stale non-playing snapshots right after playback starts',
//     () async {
//       final engine = FakeAudioEngine();
//       final parent = FakeParent(engine);
//       final player = PlayerController(parent: parent);
//
//       await player.load('/music/test-track.mp3');
//       expect(player.currentState, PlayerState.ready);
//
//       await player.play();
//       expect(player.currentState, PlayerState.playing);
//       expect(player.isPlaying, isTrue);
//
//       player.applySnapshot(
//         '/music/test-track.mp3',
//         'READY',
//         const Duration(milliseconds: 250),
//         const Duration(minutes: 3),
//         false,
//         1.0,
//       );
//
//       expect(player.currentState, PlayerState.playing);
//       expect(player.isPlaying, isTrue);
//       expect(player.position, const Duration(milliseconds: 250));
//     },
//   );
// }
//
// class FakeParent implements AudioVisualizerParent {
//   FakeParent(this._engine);
//
//   final AudioEngine _engine;
//
//   @override
//   AudioEngine get engine => _engine;
//
//   @override
//   Future<void> clearPlayback() async {}
//
//   @override
//   Future<void> loadTrack({
//     required bool autoPlay,
//     Duration? position,
//     PlaybackReason reason = PlaybackReason.playlistChanged,
//     FadeSettings? fadeSetting,
//   }) async {}
//
//   @override
//   Future<bool> handlePlayRequested() async => false;
//
//   @override
//   void notifyListeners() {}
// }
//
// class FakeAudioEngine implements AudioEngine {
//   @override
//   bool get fftDataIsPreGrouped => false;
//
//   @override
//   bool get supportsCrossfade => false;
//
//   @override
//   Stream<AudioStatus> get statusStream => const Stream<AudioStatus>.empty();
//
//   @override
//   Future<void> initialize() async {}
//
//   @override
//   Future<void> stop() async {}
//
//   @override
//   Future<void> dispose() async {}
//
//   @override
//   Future<void> load(String path) async {}
//
//   @override
//   Future<void> crossfade(
//     String path,
//     Duration duration, {
//     Duration? position,
//   }) async {}
//
//   @override
//   Future<void> transition(
//     String path,
//     Duration duration, {
//     Duration? position,
//     required bool autoPlay,
//     double? targetVolume,
//   }) async {}
//
//   @override
//   Future<void> play({Duration? fadeDuration}) async {}
//
//   @override
//   Future<void> pause({Duration? fadeDuration}) async {}
//
//   @override
//   Future<void> seek(Duration position) async {}
//
//   @override
//   Future<void> setVolume(double volume) async {}
//
//   @override
//   Future<Duration> getDuration() async => const Duration(minutes: 3);
//
//   @override
//   Future<PositionSnapshot> getCurrentPosition() async => PositionSnapshot(
//     position: Duration.zero,
//     takenAtMs: DateTime.now().millisecondsSinceEpoch,
//   );
//
//   @override
//   Future<List<double>> getLatestFft() async => const <double>[];
//
//   @override
//   Future<void> updateVisualizerFftOptions(
//     VisualizerOptimizationOptions options,
//   ) async {}
//
//   @override
//   Future<Float32List> getAudioPcm({String? path, int sampleStride = 0}) async =>
//       Float32List(0);
//
//   @override
//   Future<int> getAudioPcmChannelCount({String? path}) async => 1;
//
//   @override
//   Future<List<double>> getWaveform({
//     required String path,
//     required int expectedChunks,
//     int sampleStride = 0,
//   }) async => const <double>[];
//
//   @override
//   Future<void> setEqualizerConfig(EqualizerConfig config) async {}
//
//   @override
//   Future<EqualizerConfig> getEqualizerConfig() async {
//     throw UnimplementedError();
//   }
//
//   @override
//   Future<String?> extractFingerprint(String path) async => null;
//
//   @override
//   Future<void> prepareForFileWrite() async {}
//
//   @override
//   Future<void> finishFileWrite() async {}
//
//   @override
//   Future<bool> registerPersistentAccess(String path) async => false;
//
//   @override
//   Future<void> forgetPersistentAccess(String path) async {}
//
//   @override
//   Future<bool> hasPersistentAccess(String path) async => false;
//
//   @override
//   Future<List<String>> listPersistentAccessPaths() async => const <String>[];
//
//   @override
//   Future<bool> updateTrackMetadata({
//     required String path,
//     required Map<String, Object?> metadata,
//   }) async => false;
//
//   @override
//   Future<TrackMetadata> getTrackMetadata({
//     required String path,
//     String? fallbackMediaUri,
//   }) async {
//     throw UnimplementedError();
//   }
//
//   @override
//   Future<GeneratedTrackArtwork> generateTrackArtwork({
//     required String path,
//     required String cacheRootPath,
//     required bool saveLargeArtwork,
//     int thumbnailSize = generatedArtworkThumbnailSize,
//     double hueCohesion = 0.0,
//   }) async {
//     return const GeneratedTrackArtwork(artworkFound: false);
//   }
//
//   @override
//   Future<void> removeAllTags({String? path}) async {}
// }
