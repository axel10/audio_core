import 'package:flutter/services.dart';

import 'audio_file_access.dart';

final class AndroidAudioFileAccess implements AudioFileAccess {
  AndroidAudioFileAccess({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('my_exoplayer');

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
  Future<bool> registerPersistentAccess(String path) async => false;

  @override
  Future<void> forgetPersistentAccess(String path) async {}

  @override
  Future<bool> hasPersistentAccess(String path) async => false;

  @override
  Future<List<String>> listPersistentAccessPaths() async => const <String>[];

  @override
  Future<bool> beginScopedAccess(String path) async => true;

  @override
  Future<void> endScopedAccess(String path) async {}
}
