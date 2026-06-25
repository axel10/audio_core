import 'audio_file_access.dart';

final class NoopAudioFileAccess implements AudioFileAccess {
  const NoopAudioFileAccess();

  @override
  Future<void> prepareForFileWrite() async {}

  @override
  Future<void> finishFileWrite() async {}

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
