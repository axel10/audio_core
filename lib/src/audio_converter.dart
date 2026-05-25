import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'rust/api/simple.dart' as rust_api;

enum AudioFormat { aac, alac, aiff, caf, flac, m4a, m4b, mp3, ogg, opus, wav }

extension AudioFormatX on AudioFormat {
  String get value => switch (this) {
    AudioFormat.aac => 'aac',
    AudioFormat.alac => 'alac',
    AudioFormat.aiff => 'aiff',
    AudioFormat.caf => 'caf',
    AudioFormat.flac => 'flac',
    AudioFormat.m4a => 'm4a',
    AudioFormat.m4b => 'm4b',
    AudioFormat.mp3 => 'mp3',
    AudioFormat.ogg => 'ogg',
    AudioFormat.opus => 'opus',
    AudioFormat.wav => 'wav',
  };
}

AudioFormat audioFormatFromValue(String value) {
  return AudioFormat.values.firstWhere(
    (format) => format.value == value,
    orElse: () =>
        throw ArgumentError.value(value, 'value', 'Unsupported audio format'),
  );
}

enum AacEncoder { ffmpeg, fdkaac }

extension AacEncoderX on AacEncoder {
  String get value => switch (this) {
    AacEncoder.ffmpeg => 'ffmpeg',
    AacEncoder.fdkaac => 'fdkaac',
  };

  String get label => switch (this) {
    AacEncoder.ffmpeg => 'FFmpeg AAC',
    AacEncoder.fdkaac => 'FDK-AAC',
  };
}

AacEncoder aacEncoderFromValue(String value) {
  return AacEncoder.values.firstWhere(
    (encoder) => encoder.value == value,
    orElse: () =>
        throw ArgumentError.value(value, 'value', 'Unsupported AAC encoder'),
  );
}

enum BitRateMode { cbr, vbr }

extension BitRateModeX on BitRateMode {
  String get value => switch (this) {
    BitRateMode.cbr => 'cbr',
    BitRateMode.vbr => 'vbr',
  };
}

BitRateMode bitRateModeFromValue(String value) {
  return BitRateMode.values.firstWhere(
    (mode) => mode.value == value,
    orElse: () =>
        throw ArgumentError.value(value, 'value', 'Unsupported bit rate mode'),
  );
}

class AndroidOutputDirectory {
  const AndroidOutputDirectory({
    required this.displayPath,
    required this.treeUri,
  });

  final String displayPath;
  final String treeUri;

  Map<String, Object?> toMap() {
    return <String, Object?>{'displayPath': displayPath, 'treeUri': treeUri};
  }

  factory AndroidOutputDirectory.fromMap(Map<Object?, Object?> map) {
    return AndroidOutputDirectory(
      displayPath: map['displayPath'] as String? ?? '',
      treeUri: map['treeUri'] as String? ?? '',
    );
  }
}

class ConvertRequest {
  const ConvertRequest({
    required this.inputPath,
    required this.outputPath,
    required this.outputFormat,
    this.sampleRate,
    this.channels,
    this.bitRate,
    this.bitRateMode,
    this.ffmpegPath,
    this.aacEncoder,
    this.allowFallbackToFfmpeg = true,
    this.extraOptions,
    this.customArgs,
    this.useSystemEncoder = false,
  });

  final String inputPath;
  final String outputPath;
  final AudioFormat outputFormat;
  final int? sampleRate;
  final int? channels;
  final int? bitRate;
  final BitRateMode? bitRateMode;
  final String? ffmpegPath;
  final AacEncoder? aacEncoder;
  final bool allowFallbackToFfmpeg;
  final Map<String, String>? extraOptions;
  final List<String>? customArgs;
  final bool useSystemEncoder;

  factory ConvertRequest.forOutputDirectory({
    required String inputPath,
    required String outputDirectory,
    required AudioFormat outputFormat,
    int? sampleRate,
    int? channels,
    int? bitRate,
    BitRateMode? bitRateMode,
    String? ffmpegPath,
    AacEncoder? aacEncoder,
    bool allowFallbackToFfmpeg = true,
    Map<String, String>? extraOptions,
    List<String>? customArgs,
    bool useSystemEncoder = false,
  }) {
    final baseName = p.basenameWithoutExtension(inputPath);
    final outputPath = Platform.isAndroid
        ? p.join(
            Directory.systemTemp.path,
            'audio_converter',
            '$baseName.${outputFormat.value}',
          )
        : p.join(outputDirectory, '$baseName.${outputFormat.value}');

    return ConvertRequest(
      inputPath: inputPath,
      outputPath: outputPath,
      outputFormat: outputFormat,
      sampleRate: sampleRate,
      channels: channels,
      bitRate: bitRate,
      bitRateMode: bitRateMode,
      ffmpegPath: ffmpegPath,
      aacEncoder: aacEncoder,
      allowFallbackToFfmpeg: allowFallbackToFfmpeg,
      extraOptions: extraOptions,
      customArgs: customArgs,
      useSystemEncoder: useSystemEncoder,
    );
  }

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'inputPath': inputPath,
      'outputPath': outputPath,
      'outputFormat': outputFormat.value,
      'sampleRate': sampleRate,
      'channels': channels,
      'bitRate': bitRate,
      'bitRateMode': bitRateMode?.value,
      'ffmpegPath': ffmpegPath,
      'aacEncoder': aacEncoder?.value,
      'allowFallbackToFfmpeg': allowFallbackToFfmpeg,
      'extraOptions': extraOptions,
      'customArgs': customArgs,
      'useSystemEncoder': useSystemEncoder,
    };
  }
}

class ConversionProgress {
  const ConversionProgress({
    required this.completedFiles,
    required this.totalFiles,
    required this.currentFilePath,
    this.currentFileProgress,
    this.currentPosition,
    this.totalDuration,
    this.message,
  });

  final int completedFiles;
  final int totalFiles;
  final String currentFilePath;
  final double? currentFileProgress;
  final Duration? currentPosition;
  final Duration? totalDuration;
  final String? message;

  double? get overallProgress {
    if (totalFiles <= 0) {
      return null;
    }
    final current = currentFileProgress ?? 0.0;
    return ((completedFiles + current.clamp(0.0, 1.0)) / totalFiles)
        .clamp(0.0, 1.0)
        .toDouble();
  }
}

class ConvertResult {
  const ConvertResult({
    required this.success,
    this.command,
    this.outputPath,
    this.engine,
    this.outputFormat,
    this.errorCode,
    this.errorMessage,
    this.stdout,
    this.stderr,
    this.rawLog,
  });

  final bool success;
  final String? command;
  final String? outputPath;
  final String? engine;
  final AudioFormat? outputFormat;
  final String? errorCode;
  final String? errorMessage;
  final String? stdout;
  final String? stderr;
  final String? rawLog;

  factory ConvertResult.fromMap(Map<Object?, Object?> map) {
    final outputFormatValue = map['outputFormat'] ?? map['output_format'];
    return ConvertResult(
      success: map['success'] as bool? ?? false,
      command: map['command'] as String?,
      outputPath: (map['outputPath'] ?? map['output_path']) as String?,
      engine: map['engine'] as String?,
      outputFormat: outputFormatValue == null
          ? null
          : audioFormatFromValue(outputFormatValue.toString()),
      errorCode: (map['errorCode'] ?? map['error_code']) as String?,
      errorMessage: (map['errorMessage'] ?? map['error_message']) as String?,
      stdout: map['stdout'] as String?,
      stderr: map['stderr'] as String?,
      rawLog: (map['rawLog'] ?? map['raw_log']) as String?,
    );
  }

  ConvertResult copyWith({
    bool? success,
    String? command,
    String? outputPath,
    String? engine,
    AudioFormat? outputFormat,
    String? errorCode,
    String? errorMessage,
    String? stdout,
    String? stderr,
    String? rawLog,
  }) {
    return ConvertResult(
      success: success ?? this.success,
      command: command ?? this.command,
      outputPath: outputPath ?? this.outputPath,
      engine: engine ?? this.engine,
      outputFormat: outputFormat ?? this.outputFormat,
      errorCode: errorCode ?? this.errorCode,
      errorMessage: errorMessage ?? this.errorMessage,
      stdout: stdout ?? this.stdout,
      stderr: stderr ?? this.stderr,
      rawLog: rawLog ?? this.rawLog,
    );
  }
}

class ConverterCapabilities {
  const ConverterCapabilities({
    required this.engine,
    required this.supportedOutputFormats,
    required this.supportsProgress,
    required this.supportsCancellation,
    required this.requiresExternalBinary,
    this.notes,
  });

  final String engine;
  final List<AudioFormat> supportedOutputFormats;
  final bool supportsProgress;
  final bool supportsCancellation;
  final bool requiresExternalBinary;
  final String? notes;

  factory ConverterCapabilities.fromMap(Map<Object?, Object?> map) {
    final rawFormats = map['supportedOutputFormats'];
    final formats = rawFormats is List
        ? rawFormats
              .map((value) => audioFormatFromValue(value.toString()))
              .toList(growable: false)
        : const <AudioFormat>[];
    return ConverterCapabilities(
      engine: map['engine'] as String? ?? 'unknown',
      supportedOutputFormats: formats,
      supportsProgress: map['supportsProgress'] as bool? ?? false,
      supportsCancellation: map['supportsCancellation'] as bool? ?? false,
      requiresExternalBinary: map['requiresExternalBinary'] as bool? ?? false,
      notes: map['notes'] as String?,
    );
  }
}

class ConvertAndSaveResult {
  const ConvertAndSaveResult({
    required this.conversionResult,
    this.savedPath,
    this.temporaryPath,
    this.saveCancelled = false,
    this.saveErrorMessage,
  });

  final ConvertResult conversionResult;
  final String? savedPath;
  final String? temporaryPath;
  final bool saveCancelled;
  final String? saveErrorMessage;

  bool get success =>
      conversionResult.success && !saveCancelled && saveErrorMessage == null;

  String? get outputPath =>
      savedPath ?? temporaryPath ?? conversionResult.outputPath;

  String? get errorMessage {
    if (saveErrorMessage != null) {
      return saveErrorMessage;
    }
    if (saveCancelled) {
      return 'Save dialog was cancelled.';
    }
    return conversionResult.errorMessage;
  }
}

typedef AudioConverterProgressCallback =
    void Function(ConversionProgress progress);

class AudioConverter {
  static const MethodChannel _androidSafChannel = MethodChannel(
    'com.example.audio_converter/saf',
  );
  static const MethodChannel _appleFileAccessChannel = MethodChannel(
    'audio_core.player',
  );
  static const MethodChannel _appleConverterChannel = MethodChannel(
    'audio_core.audio_converter',
  );
  static const MethodChannel _androidConverterChannel = MethodChannel(
    'my_exoplayer',
  );

  bool get _usesAppleTranscoder => Platform.isIOS || Platform.isMacOS;

  Future<ConverterCapabilities> getCapabilities() async {
    if (_usesAppleTranscoder) {
      final raw = await _appleConverterChannel.invokeMapMethod<String, Object?>(
        'getCapabilities',
      );
      if (raw == null) {
        throw StateError('Apple audio converter returned no capabilities.');
      }
      return ConverterCapabilities.fromMap(raw);
    }

    final raw = rust_api.getCapabilities();
    return ConverterCapabilities.fromMap(
      jsonDecode(raw) as Map<Object?, Object?>,
    );
  }

  Future<ConvertResult> convertFile(
    ConvertRequest request, {
    AudioConverterProgressCallback? onProgress,
  }) async {
    if (Platform.isAndroid && request.useSystemEncoder && request.outputFormat == AudioFormat.m4a) {
      onProgress?.call(
        ConversionProgress(
          completedFiles: 0,
          totalFiles: 1,
          currentFilePath: request.inputPath,
          currentFileProgress: 0.0,
          currentPosition: Duration.zero,
          message: 'Starting conversion',
        ),
      );

      try {
        final rawResult = await _androidConverterChannel.invokeMapMethod<String, Object?>(
          'convertFileWithTransformer',
          request.toMap(),
        );
        if (rawResult == null) {
          throw StateError('Android audio converter returned no result.');
        }

        final result = ConvertResult.fromMap(rawResult);
        onProgress?.call(
          ConversionProgress(
            completedFiles: 1,
            totalFiles: 1,
            currentFilePath: result.outputPath ?? request.inputPath,
            currentFileProgress: 1.0,
            currentPosition: null,
            totalDuration: null,
            message: result.success ? 'Completed' : 'Failed',
          ),
        );
        return result;
      } catch (error) {
        final message = error.toString();
        onProgress?.call(
          ConversionProgress(
            completedFiles: 1,
            totalFiles: 1,
            currentFilePath: request.inputPath,
            currentFileProgress: 1.0,
            message: 'Failed',
          ),
        );
        return ConvertResult(
          success: false,
          engine: 'Media3Transformer',
          outputFormat: request.outputFormat,
          errorCode: 'native_bridge_failed',
          errorMessage: message,
        );
      }
    }

    if (_usesAppleTranscoder) {
      onProgress?.call(
        ConversionProgress(
          completedFiles: 0,
          totalFiles: 1,
          currentFilePath: request.inputPath,
          currentFileProgress: 0.0,
          currentPosition: Duration.zero,
          message: 'Starting conversion',
        ),
      );

      try {
        final rawResult = await _appleConverterChannel
            .invokeMapMethod<String, Object?>('convertFile', request.toMap());
        if (rawResult == null) {
          throw StateError('Apple audio converter returned no result.');
        }

        final result = ConvertResult.fromMap(rawResult);
        onProgress?.call(
          ConversionProgress(
            completedFiles: 1,
            totalFiles: 1,
            currentFilePath: result.outputPath ?? request.inputPath,
            currentFileProgress: 1.0,
            currentPosition: null,
            totalDuration: null,
            message: result.success ? 'Completed' : 'Failed',
          ),
        );
        return result;
      } catch (error) {
        final message = error.toString();
        onProgress?.call(
          ConversionProgress(
            completedFiles: 1,
            totalFiles: 1,
            currentFilePath: request.inputPath,
            currentFileProgress: 1.0,
            message: 'Failed',
          ),
        );
        return ConvertResult(
          success: false,
          engine: 'SFBAudioEngine',
          outputFormat: request.outputFormat,
          errorCode: 'native_bridge_failed',
          errorMessage: message,
        );
      }
    }

    final rawEvents = rust_api.convertFileWithProgress(
      requestJson: jsonEncode(request.toMap()),
    );
    ConvertResult? result;
    await for (final rawEvent in rawEvents) {
      final event = jsonDecode(rawEvent);
      if (event is! Map) {
        continue;
      }
      switch (event['kind']?.toString()) {
        case 'progress':
          final currentPositionUs =
              event['currentPositionUs'] ?? event['current_position_us'];
          final totalDurationUs =
              event['totalDurationUs'] ?? event['total_duration_us'];
          onProgress?.call(
            ConversionProgress(
              completedFiles:
                  (event['completedFiles'] ?? event['completed_files'])
                      as int? ??
                  0,
              totalFiles:
                  (event['totalFiles'] ?? event['total_files']) as int? ?? 1,
              currentFilePath:
                  (event['currentFilePath'] ?? event['current_file_path'])
                      as String? ??
                  request.inputPath,
              currentFileProgress:
                  ((event['currentFileProgress'] ??
                              event['current_file_progress'])
                          as num?)
                      ?.toDouble(),
              currentPosition: currentPositionUs is num
                  ? Duration(microseconds: currentPositionUs.toInt())
                  : null,
              totalDuration: totalDurationUs is num
                  ? Duration(microseconds: totalDurationUs.toInt())
                  : null,
              message: event['message'] as String?,
            ),
          );
          break;
        case 'result':
          final rawResult = event['result'];
          if (rawResult is Map) {
            result = ConvertResult.fromMap(rawResult.cast<Object?, Object?>());
          }
          break;
      }
    }

    if (result == null) {
      throw StateError('Rust progress stream ended without a final result.');
    }
    return result;
  }

  Future<ConvertResult> convertToOutputDirectory({
    required String inputPath,
    required String outputDirectory,
    required AudioFormat outputFormat,
    int? sampleRate,
    int? channels,
    int? bitRate,
    BitRateMode? bitRateMode,
    String? ffmpegPath,
    AacEncoder? aacEncoder,
    bool allowFallbackToFfmpeg = true,
    Map<String, String>? extraOptions,
    List<String>? customArgs,
    AndroidOutputDirectory? androidOutputDirectory,
    bool useSystemEncoder = false,
    AudioConverterProgressCallback? onProgress,
  }) async {
    final request = ConvertRequest.forOutputDirectory(
      inputPath: inputPath,
      outputDirectory: outputDirectory,
      outputFormat: outputFormat,
      sampleRate: sampleRate,
      channels: channels,
      bitRate: bitRate,
      bitRateMode: bitRateMode,
      ffmpegPath: ffmpegPath,
      aacEncoder: aacEncoder,
      allowFallbackToFfmpeg: allowFallbackToFfmpeg,
      extraOptions: extraOptions,
      customArgs: customArgs,
      useSystemEncoder: useSystemEncoder,
    );

    if (!Platform.isIOS && !Platform.isMacOS) {
      return convertFile(request, onProgress: onProgress);
    }

    final scopedOutputDirectory = outputDirectory.trim();
    if (scopedOutputDirectory.isEmpty) {
      return convertFile(request, onProgress: onProgress);
    }

    final beganInputAccess = await _beginScopedAccess(inputPath);
    final beganOutputAccess = await _beginScopedAccess(scopedOutputDirectory);
    try {
      return await convertFile(request, onProgress: onProgress);
    } finally {
      if (beganOutputAccess) {
        await _endScopedAccess(scopedOutputDirectory);
      }
      if (beganInputAccess) {
        await _endScopedAccess(inputPath);
      }
    }
  }

  Future<List<ConvertResult>> convertFiles(
    List<ConvertRequest> requests, {
    AudioConverterProgressCallback? onProgress,
  }) async {
    final results = <ConvertResult>[];
    for (var index = 0; index < requests.length; index++) {
      final request = requests[index];
      final result = await convertFile(request, onProgress: onProgress);
      results.add(result);
    }
    return results;
  }

  Future<String?> pickInputFile({List<String>? allowedExtensions}) async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions:
          allowedExtensions ??
          <String>[
            'aac',
            'aif',
            'aiff',
            'caf',
            'flac',
            'm4a',
            'm4b',
            'mp4',
            'mp3',
            'ogg',
            'opus',
            'wav',
          ],
      allowMultiple: false,
      withData: false,
    );
    return result?.files.single.path;
  }

  Future<String?> pickOutputDirectory() async {
    return FilePicker.getDirectoryPath();
  }

  Future<bool> _beginScopedAccess(String path) async {
    if (!Platform.isIOS && !Platform.isMacOS) {
      return true;
    }

    try {
      final bool? result = await _appleFileAccessChannel.invokeMethod<bool>(
        'beginScopedAccess',
        <String, Object?>{'path': path},
      );
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _endScopedAccess(String path) async {
    if (!Platform.isIOS && !Platform.isMacOS) {
      return;
    }

    try {
      await _appleFileAccessChannel.invokeMethod(
        'endScopedAccess',
        <String, Object?>{'path': path},
      );
    } catch (_) {
      // Best-effort cleanup.
    }
  }

  Future<AndroidOutputDirectory?> pickAndroidOutputDirectory() async {
    if (!Platform.isAndroid) {
      return null;
    }

    final result = await _androidSafChannel.invokeMapMethod<String, Object?>(
      'pickOutputDirectory',
    );
    if (result == null) {
      return null;
    }

    return AndroidOutputDirectory.fromMap(result);
  }

  Future<String?> saveFileToAndroidDirectory({
    required AndroidOutputDirectory directory,
    required String sourcePath,
    String? fileName,
  }) async {
    if (!Platform.isAndroid) {
      return null;
    }

    final resolvedFileName = fileName?.trim().isNotEmpty == true
        ? fileName!.trim()
        : p.basename(sourcePath);
    final result = await _androidSafChannel.invokeMapMethod<String, Object?>(
      'saveFileToDirectory',
      <String, Object?>{
        'treeUri': directory.treeUri,
        'sourcePath': sourcePath,
        'fileName': resolvedFileName,
      },
    );
    return result?['savedUri']?.toString();
  }

  Future<ConvertAndSaveResult> convertAndSaveToAndroidDirectory(
    ConvertRequest request,
    AndroidOutputDirectory directory, {
    AudioConverterProgressCallback? onProgress,
  }) async {
    final result = await convertFile(request, onProgress: onProgress);
    if (!result.success || result.outputPath == null) {
      return ConvertAndSaveResult(
        conversionResult: result,
        temporaryPath: result.outputPath,
      );
    }

    final tempPath = result.outputPath!;
    try {
      final savedUri = await saveFileToAndroidDirectory(
        directory: directory,
        sourcePath: tempPath,
        fileName: p.basename(tempPath),
      );
      if (savedUri == null) {
        return ConvertAndSaveResult(
          conversionResult: result,
          temporaryPath: tempPath,
          saveErrorMessage:
              'Android export failed: no saved path was returned.',
        );
      }

      try {
        await File(tempPath).delete();
      } catch (_) {
        // Cleanup is best-effort.
      }

      return ConvertAndSaveResult(
        conversionResult: result.copyWith(outputPath: savedUri),
        savedPath: savedUri,
        temporaryPath: tempPath,
      );
    } catch (error) {
      return ConvertAndSaveResult(
        conversionResult: result,
        temporaryPath: tempPath,
        saveErrorMessage: 'Android export failed: $error',
      );
    }
  }

  String buildOutputPath({
    required String inputPath,
    required String outputDirectory,
    required AudioFormat outputFormat,
    bool ensureUnique = true,
  }) {
    final normalizedOutputDirectory = outputDirectory.trim();
    final baseName = p.basenameWithoutExtension(inputPath);
    final ext = outputFormat.value;
    final preferredPath = p.join(normalizedOutputDirectory, '$baseName.$ext');
    if (!ensureUnique || !File(preferredPath).existsSync()) {
      return preferredPath;
    }

    for (var index = 1; index < 1000; index++) {
      final candidate = p.join(
        normalizedOutputDirectory,
        '$baseName ($index).$ext',
      );
      if (!File(candidate).existsSync()) {
        return candidate;
      }
    }

    return preferredPath;
  }
}
