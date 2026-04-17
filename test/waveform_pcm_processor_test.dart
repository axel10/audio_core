import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('waveform processor keeps output in range', () {
    const processor = WaveformPcmProcessor();

    final waveform = processor.process(
      Float32List.fromList(<double>[
        0.05,
        0.04,
        0.06,
        0.05,
        0.90,
        0.80,
        0.88,
        0.92,
      ]),
      expectedChunks: 2,
    );

    expect(waveform, hasLength(2));
    expect(waveform[0], inInclusiveRange(0.0, 1.0));
    expect(waveform[1], inInclusiveRange(0.0, 1.0));
    expect(waveform[1], greaterThan(waveform[0]));
    expect(waveform[1], closeTo(1.0, 1e-9));
  });

  test('waveform processor mixes stereo to mono before reduction', () {
    const processor = WaveformPcmProcessor();
    final waveform = processor.process(
      Float32List.fromList(<double>[0.1, 0.3, 0.1, 0.3, 0.8, 0.6, 0.8, 0.6]),
      expectedChunks: 2,
      channels: 2,
    );

    expect(waveform, hasLength(2));
    expect(waveform[1], greaterThan(waveform[0]));
  });

  test('waveform processor can skip normalization', () {
    const processor = WaveformPcmProcessor();

    final waveform = processor.process(
      Float32List.fromList(<double>[
        0.10,
        0.10,
        0.10,
        0.10,
        0.50,
        0.50,
        0.50,
        0.50,
      ]),
      expectedChunks: 2,
    );

    expect(waveform, hasLength(2));
    expect(waveform[0], closeTo(0.1, 1e-6));
    expect(waveform[1], closeTo(0.5, 1e-6));
    expect(waveform[1], greaterThan(waveform[0]));
  });
}
