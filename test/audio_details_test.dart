import 'package:audio_core/audio_core.dart';
import 'package:audio_core/src/rust/api/simple/metadata.dart' as rust;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AudioDetails mapping from Rust struct matches expected values', () {
    final rustDetails = rust.AudioDetails(
      formatName: 'Mpeg',
      codecName: 'Mpeg',
      durationMs: 123450,
      bitrate: 320000,
      sampleRate: 44100,
      channels: 2,
      bitDepth: 0,
      bitrateMode: 'CBR',
      fileSize: 5000000,
    );

    final details = AudioDetails.fromRust(rustDetails);

    expect(details.formatName, equals('mp3'));
    expect(details.codecName, equals('mp3'));
    expect(details.duration.inMilliseconds, equals(123450));
    expect(details.bitrate, equals(320000));
    expect(details.sampleRate, equals(44100));
    expect(details.channels, equals(2));
    expect(details.bitDepth, isNull);
    expect(details.bitrateMode, equals('CBR'));
    expect(details.fileSize, equals(5000000));
  });

  test('AudioDetails mapping handles flac and mp4 correctly', () {
    final rustDetails = rust.AudioDetails(
      formatName: 'Mp4',
      codecName: 'Mp4',
      durationMs: 250000,
      bitrate: 256000,
      sampleRate: 48000,
      channels: 6,
      bitDepth: 24,
      bitrateMode: 'VBR',
      fileSize: 12000000,
    );

    final details = AudioDetails.fromRust(rustDetails);

    expect(details.formatName, equals('m4a'));
    expect(details.codecName, equals('aac'));
    expect(details.duration.inMilliseconds, equals(250000));
    expect(details.bitDepth, equals(24));
  });
}
