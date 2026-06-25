abstract interface class AudioFileAccess {
  Future<void> prepareForFileWrite();
  Future<void> finishFileWrite();

  Future<bool> registerPersistentAccess(String path);
  Future<void> forgetPersistentAccess(String path);
  Future<bool> hasPersistentAccess(String path);
  Future<List<String>> listPersistentAccessPaths();

  Future<bool> beginScopedAccess(String path);
  Future<void> endScopedAccess(String path);
}
