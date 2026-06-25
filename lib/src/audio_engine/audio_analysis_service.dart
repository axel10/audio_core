import 'dart:typed_data';

import '../track_artwork.dart';

abstract interface class AudioAnalysisService {
  Future<List<double>> getWaveform({
    required String path,
    required int expectedChunks,
    int sampleStride = 0,
  });

  Future<Float32List> getAudioPcm({String? path, int sampleStride = 0});

  Future<int> getAudioPcmChannelCount({String? path});

  Future<String?> extractFingerprint(String path);

  Future<GeneratedTrackArtwork> generateTrackArtwork({
    required String path,
    Uint8List? artworkBytes,
    required String cacheRootPath,
    required bool saveLargeArtwork,
    TrackArtworkOptions options = const TrackArtworkOptions(),
  });
}
