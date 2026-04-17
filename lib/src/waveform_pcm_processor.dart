import 'dart:math' as math;
import 'dart:typed_data';

/// Converts raw PCM samples into simple waveform bars.
///
/// The processor intentionally stays close to Android's current behavior:
/// mix interleaved channels into mono, compute a short-window RMS envelope,
/// then downsample by taking the max RMS value for each visible bar.
class WaveformPcmProcessor {
  const WaveformPcmProcessor();

  static const int _rmsWindowsPerChunk = 8;

  List<double> process(
    Float32List pcm, {
    required int expectedChunks,
    int channels = 1,
  }) {
    if (expectedChunks <= 0 || pcm.isEmpty) {
      return const <double>[];
    }

    final mono = _toMonoSamples(pcm, channels: channels);
    if (mono.isEmpty) {
      return List<double>.filled(expectedChunks, 0.0);
    }

    return _reduceToChunks(mono, expectedChunks);
  }

  List<double> _toMonoSamples(Float32List pcm, {required int channels}) {
    final safeChannels = channels <= 0 ? 1 : channels;
    if (safeChannels == 1) {
      return pcm.map((sample) => sample.toDouble()).toList(growable: false);
    }

    final frameCount = pcm.length ~/ safeChannels;
    final out = List<double>.filled(frameCount, 0.0);
    for (var frame = 0; frame < frameCount; frame++) {
      final base = frame * safeChannels;
      var sum = 0.0;
      for (var ch = 0; ch < safeChannels; ch++) {
        sum += pcm[base + ch];
      }
      out[frame] = sum / safeChannels;
    }
    return out;
  }

  List<double> _reduceToChunks(List<double> samples, int expectedChunks) {
    final out = List<double>.filled(expectedChunks, 0.0);
    if (samples.isEmpty) return out;

    final windowCount = math.max(
      expectedChunks,
      math.min(samples.length, expectedChunks * _rmsWindowsPerChunk),
    );
    final envelope = List<double>.filled(windowCount, 0.0);

    for (var window = 0; window < windowCount; window++) {
      final start = (window * samples.length) ~/ windowCount;
      final end = ((window + 1) * samples.length) ~/ windowCount;
      if (end <= start) {
        continue;
      }
      envelope[window] = _computeRms(samples, start, end);
    }

    for (var chunk = 0; chunk < expectedChunks; chunk++) {
      final start = (chunk * windowCount) ~/ expectedChunks;
      final end = ((chunk + 1) * windowCount) ~/ expectedChunks;
      var maxValue = 0.0;
      for (var i = start; i < end; i++) {
        if (envelope[i] > maxValue) {
          maxValue = envelope[i];
        }
      }
      out[chunk] = maxValue.clamp(0.0, 1.0);
    }

    return out;
  }

  double _computeRms(List<double> samples, int start, int end) {
    var sum = 0.0;
    for (var i = start; i < end; i++) {
      final sample = samples[i];
      sum += sample * sample;
    }
    return math.sqrt(sum / (end - start));
  }
}
