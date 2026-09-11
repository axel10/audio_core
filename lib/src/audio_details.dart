import 'rust/api/simple/metadata.dart' as rust;

class AudioDetails {
  final String formatName;
  final String codecName;
  final Duration duration;
  final int bitrate;
  final int sampleRate;
  final int channels;
  final int? bitDepth;
  final String bitrateMode;
  final int fileSize;

  const AudioDetails({
    required this.formatName,
    required this.codecName,
    required this.duration,
    required this.bitrate,
    required this.sampleRate,
    required this.channels,
    this.bitDepth,
    required this.bitrateMode,
    required this.fileSize,
  });

  factory AudioDetails.fromRust(rust.AudioDetails details) {
    // Map lofty format/codec names to more common ones
    final rawFormat = details.formatName.toLowerCase();
    String formatName = rawFormat;
    if (rawFormat == 'mpeg') {
      formatName = 'mp3';
    } else if (rawFormat == 'mp4') {
      formatName = 'm4a';
    }

    final rawCodec = details.codecName.toLowerCase();
    String codecName = rawCodec;
    if (rawCodec == 'mpeg') {
      codecName = 'mp3';
    } else if (rawCodec == 'mp4') {
      codecName = 'aac';
    }

    return AudioDetails(
      formatName: formatName,
      codecName: codecName,
      duration: Duration(milliseconds: details.durationMs),
      bitrate: details.bitrate,
      sampleRate: details.sampleRate,
      channels: details.channels,
      bitDepth: (details.bitDepth == null || details.bitDepth == 0) ? null : details.bitDepth,
      bitrateMode: details.bitrateMode,
      fileSize: details.fileSize,
    );
  }

  AudioDetails copyWith({
    String? formatName,
    String? codecName,
    Duration? duration,
    int? bitrate,
    int? sampleRate,
    int? channels,
    int? bitDepth,
    String? bitrateMode,
    int? fileSize,
  }) {
    return AudioDetails(
      formatName: formatName ?? this.formatName,
      codecName: codecName ?? this.codecName,
      duration: duration ?? this.duration,
      bitrate: bitrate ?? this.bitrate,
      sampleRate: sampleRate ?? this.sampleRate,
      channels: channels ?? this.channels,
      bitDepth: bitDepth ?? this.bitDepth,
      bitrateMode: bitrateMode ?? this.bitrateMode,
      fileSize: fileSize ?? this.fileSize,
    );
  }

  @override
  String toString() {
    return 'AudioDetails(formatName: $formatName, codecName: $codecName, duration: $duration, bitrate: $bitrate, sampleRate: $sampleRate, channels: $channels, bitDepth: $bitDepth, bitrateMode: $bitrateMode, fileSize: $fileSize)';
  }
}
