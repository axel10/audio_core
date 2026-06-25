import 'package:flutter/services.dart';

import 'audio_file_access.dart';

final class AppleAudioFileAccess implements AudioFileAccess {
  AppleAudioFileAccess({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('audio_core.player');

  final MethodChannel _channel;

  @override
  Future<void> prepareForFileWrite() async {
    await _channel.invokeMethod('prepareForFileWrite', <String, Object?>{
      'playerId': 'main',
    });
  }

  @override
  Future<void> finishFileWrite() async {
    await _channel.invokeMethod('finishFileWrite', <String, Object?>{
      'playerId': 'main',
    });
  }

  @override
  Future<bool> registerPersistentAccess(String path) async {
    final bool? result = await _channel.invokeMethod<bool>(
      'registerPersistentAccess',
      <String, Object?>{'path': path},
    );
    return result ?? false;
  }

  @override
  Future<void> forgetPersistentAccess(String path) async {
    await _channel.invokeMethod('forgetPersistentAccess', <String, Object?>{
      'path': path,
    });
  }

  @override
  Future<bool> hasPersistentAccess(String path) async {
    final bool? result = await _channel.invokeMethod<bool>(
      'hasPersistentAccess',
      <String, Object?>{'path': path},
    );
    return result ?? false;
  }

  @override
  Future<List<String>> listPersistentAccessPaths() async {
    final List<dynamic>? result = await _channel.invokeMethod(
      'listPersistentAccessPaths',
    );
    if (result == null) return const <String>[];
    return result
        .map((entry) => entry.toString())
        .where((entry) => entry.trim().isNotEmpty)
        .toList(growable: false);
  }

  @override
  Future<bool> beginScopedAccess(String path) async {
    final bool? result = await _channel.invokeMethod<bool>(
      'beginScopedAccess',
      <String, Object?>{'path': path},
    );
    return result ?? false;
  }

  @override
  Future<void> endScopedAccess(String path) async {
    await _channel.invokeMethod('endScopedAccess', <String, Object?>{
      'path': path,
    });
  }
}
