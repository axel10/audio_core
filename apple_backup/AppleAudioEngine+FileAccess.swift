import Foundation

extension AppleAudioEngine {
  func prepareForFileWrite(path: String? = nil) throws {
    if let path {
      let normalizedPath = normalizedFilePath(path)
      if isPreparedAccessPath(normalizedPath) {
        return
      }

      if currentDeck.loadedURL?.path != normalizedPath {
        _ = try fileAccess.acquireAccess(for: normalizedPath)
        insertPreparedAccessPath(normalizedPath)
        return
      }
    }

    guard let path = currentDeck.loadedURL?.path else { return }
    if isPreparedAccessPath(path) {
      return
    }

    let wasPlaying = currentDeck.isPlaying
    let positionMs = getCurrentPositionMs()
    let volume = latestVolume
    pendingEdit = PendingEdit(
      path: path,
      positionMs: positionMs,
      wasPlaying: wasPlaying,
      volume: volume
    )
    stopPlayback(releasingFile: true, preservePosition: true)
    _ = try fileAccess.acquireAccess(for: path)
    insertPreparedAccessPath(path)
  }

  func prepareForFileWrite(paths: [String]) throws {
    let normalizedPaths = Self.normalizedUniquePaths(paths)
    for path in normalizedPaths {
      try prepareForFileWrite(path: path)
    }
  }

  func finishFileWrite(path: String? = nil) throws {
    debugPrint(
      "[AppleAudioEngine] finishFileWrite request path=\(path ?? "nil") " +
      "current=\(currentDeck.loadedURL?.path ?? "nil") pending=\(pendingEdit?.path ?? "nil")"
    )
    if let path {
      let normalizedPath = normalizedFilePath(path)
      if currentDeck.loadedURL?.path != normalizedPath {
        fileAccess.releaseAccess(for: normalizedPath)
        removePreparedAccessPath(normalizedPath)
        return
      }
    }

    guard let pendingEdit else { return }
    try load(path: pendingEdit.path)
    try seek(positionMs: pendingEdit.positionMs)
    try setVolume(pendingEdit.volume)
    if pendingEdit.wasPlaying {
      try play(fadeDurationMs: 0, targetVolume: pendingEdit.volume)
    }
    self.pendingEdit = nil
    removePreparedAccessPath(pendingEdit.path)
  }

  func finishFileWrite(paths: [String]) throws {
    let normalizedPaths = Self.normalizedUniquePaths(paths)
    for path in normalizedPaths {
      try finishFileWrite(path: path)
    }
  }

  func registerPersistentAccess(path: String) -> Bool {
    fileAccess.registerPersistentAccess(for: path)
  }

  func forgetPersistentAccess(path: String) {
    fileAccess.forgetPersistentAccess(for: path)
  }

  func hasPersistentAccess(path: String) -> Bool {
    fileAccess.hasPersistentAccess(for: path)
  }

  func listPersistentAccessPaths() -> [String] {
    fileAccess.listPersistentAccessPaths()
  }

  func beginScopedAccess(path: String) -> Bool {
    do {
      _ = try fileAccess.acquireAccess(for: path)
      return true
    } catch {
      return false
    }
  }

  func endScopedAccess(path: String) {
    fileAccess.releaseAccess(for: path)
  }

  func dispose() {
    debugPrint(
      "[AppleAudioEngine] dispose current=\(currentDeck.loadedURL?.path ?? "nil") " +
      "incoming=\(incomingDeck.loadedURL?.path ?? "nil")"
    )
    cancelSeekDebounce()
    fadeTimer?.invalidate()
    fadeTimer = nil
    pendingEdit = nil
    clearPreparedAccessPaths()
    stopPlayback(releasingFile: true, preservePosition: false)
    fileAccess.releaseAllAccess()
    currentDeck.loadedURL = nil
    currentDeck.loadedFile = nil
    incomingDeck.loadedURL = nil
    incomingDeck.loadedFile = nil
  }

  func normalizedFilePath(_ path: String) -> String {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("file://"), let url = URL(string: trimmed) {
      return url.standardizedFileURL.resolvingSymlinksInPath().path
    }
    return URL(fileURLWithPath: trimmed).standardizedFileURL.resolvingSymlinksInPath().path
  }

  static func normalizedUniquePaths(_ paths: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for path in paths {
      let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
      let url: URL
      if trimmed.hasPrefix("file://"), let parsed = URL(string: trimmed) {
        url = parsed
      } else {
        url = URL(fileURLWithPath: trimmed)
      }
      let normalized = url.standardizedFileURL.resolvingSymlinksInPath().path
      if seen.insert(normalized).inserted {
        result.append(normalized)
      }
    }
    return result
  }
}
