import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class AppLog {
  static const List<String> _allowedPrefixes = <String>[
    '[AudioCore]',
    '[AudioCoreController]',
    'AudioCoreController:',
    '[PlayerController]',
    '[PlaylistController]',
    '[AndroidAudioEngine]',
    '[AppleAudioEngine]',
    '[EqualizerController]',
    '[SequentialFadeTransition]',
    '[NativeCrossfadeTransition]',
    '[Chromaprint]',
  ];

  static bool _installed = false;
  static Future<void>? _initFuture;
  static File? _logFile;
  static Future<void> _writeQueue = Future<void>.value();

  static Future<void> ensureInitialized() {
    _initFuture ??= _initialize();
    return _initFuture!;
  }

  static void install() {
    if (_installed) return;
    debugPrint = flutterDebugPrint;
    _installed = true;
  }

  static void flutterDebugPrint(String? message, {int? wrapWidth}) {
    if (message == null || !_shouldCapture(message)) {
      return;
    }

    if (kDebugMode) {
      stdout.writeln(message);
    }

    unawaited(
      ensureInitialized().then((_) => _appendLine('FLUTTER', message)),
    );
  }

  static void d(String message, {String tag = 'AudioCore'}) {
    _enqueue(tag: tag, level: 'D', message: message);
  }

  static void i(String message, {String tag = 'AudioCore'}) {
    _enqueue(tag: tag, level: 'I', message: message);
  }

  static void w(String message, {String tag = 'AudioCore'}) {
    _enqueue(tag: tag, level: 'W', message: message);
  }

  static void e(
    String message, {
    String tag = 'AudioCore',
    Object? error,
    StackTrace? stackTrace,
  }) {
    final fullMessage = <String>[
      message,
      if (error != null) 'error=$error',
      if (stackTrace != null) stackTrace.toString(),
    ].join(' | ');
    _enqueue(tag: tag, level: 'E', message: fullMessage);
  }

  static void _enqueue({
    required String tag,
    required String level,
    required String message,
  }) {
    if (kDebugMode) {
      stdout.writeln(_formatLine('$level/$tag', message));
    }

    unawaited(
      ensureInitialized().then((_) => _appendLine('$level/$tag', message)),
    );
  }

  static Future<void> _appendLine(String channel, String message) async {
    final logFile = _logFile;
    if (logFile == null) {
      return;
    }

    final line = _formatLine(channel, message);
    _writeQueue = _writeQueue.then((_) async {
      await logFile.writeAsString(
        '$line${Platform.lineTerminator}',
        mode: FileMode.append,
        flush: true,
      );
    });

    await _writeQueue;
  }

  static String _formatLine(String channel, String message) {
    final timestamp = DateTime.now().toIso8601String();
    return '[$timestamp][$channel] $message';
  }

  static bool _shouldCapture(String message) {
    for (final prefix in _allowedPrefixes) {
      if (message.startsWith(prefix)) {
        return true;
      }
    }
    return false;
  }

  static Future<void> _initialize() async {
    try {
      Directory baseDir;
      try {
        baseDir = await getApplicationDocumentsDirectory();
      } catch (_) {
        baseDir = Directory.systemTemp;
      }

      final logDir = Directory(
        '${baseDir.path}${Platform.pathSeparator}audio_core_logs',
      );
      if (!await logDir.exists()) {
        await logDir.create(recursive: true);
      }
      _logFile = File(
        '${logDir.path}${Platform.pathSeparator}flutter.log',
      );
    } catch (_) {
      _logFile = null;
    }
  }
}
