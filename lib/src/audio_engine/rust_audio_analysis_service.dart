import 'dart:typed_data';

import '../rust/api/simple/audio_fingerprint.dart' as audio_fingerprint;
import '../rust/api/simple/controller.dart' as controller;
import '../rust/api/simple/metadata.dart' as rust;
import '../track_artwork.dart';
import 'audio_analysis_service.dart';

final class RustAudioAnalysisService implements AudioAnalysisService {
  const RustAudioAnalysisService();

  @override
  Future<List<double>> getWaveform({
    required String path,
    required int expectedChunks,
    int sampleStride = 0,
  }) async {
    if (expectedChunks <= 0) return const <double>[];
    final waveform = await controller.getAudioWaveform(
      path: path,
      expectedChunks: BigInt.from(expectedChunks),
      sampleStride: BigInt.from(sampleStride),
    );
    return waveform.toList(growable: false);
  }

  @override
  Future<Float32List> getAudioPcm({String? path, int sampleStride = 0}) {
    return controller.getAudioPcm(
      path: path,
      sampleStride: BigInt.from(sampleStride),
    );
  }

  @override
  Future<int> getAudioPcmChannelCount({String? path}) {
    return controller.getAudioPcmChannelCount(path: path);
  }

  @override
  Future<String?> extractFingerprint(String path) async {
    try {
      return await audio_fingerprint.getAudioFingerprint(path: path);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<GeneratedTrackArtwork> generateTrackArtwork({
    required String path,
    Uint8List? artworkBytes,
    required String cacheRootPath,
    required bool saveLargeArtwork,
    TrackArtworkOptions options = const TrackArtworkOptions(),
  }) async {
    final result = await rust.generateTrackArtwork(
      path: path,
      artworkBytes: artworkBytes,
      cacheRootPath: cacheRootPath,
      saveLargeArtwork: saveLargeArtwork,
      thumbnailSize: options.thumbnailSize,
      meshStylePreset: options.meshStylePreset.index,
      hueCohesion: options.hueCohesion,
      paletteBlurRadius: options.paletteBlurRadius,
      meshMuddyPenaltyMultiplier: options.meshMuddyPenaltyMultiplier,
      meshPopulationStrength: options.meshPopulationStrength,
      meshContrastStrength: options.meshContrastStrength,
      meshHarmonyStrength: options.meshHarmonyStrength,
      meshVibrancyStrength: options.meshVibrancyStrength,
    );
    return GeneratedTrackArtwork.fromRust(result);
  }
}
