import Foundation

final class SecurityScopedBookmarkStore {
  private let storageKey = "audio_core.securityScopedBookmarks"
  private var bookmarks: [String: Data]
  private let stateQueue = DispatchQueue(label: "audio_core.security_scoped_bookmark_store")

  init() {
    if let stored = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: Data] {
      bookmarks = stored
    } else {
      bookmarks = [:]
    }
  }

  /// Resolves the URL for a path.
  /// 1. Exact match for single-file bookmark (e.g. externally opened file).
  /// 2. If not matched, traverses upwards to find any ancestor folder with a stored bookmark.
  /// Returns a tuple of (targetURL, resolvedParentScopeURL?).
  func resolveURL(for path: String) throws -> (url: URL, parentScopeURL: URL?) {
    let candidateURL = Self.url(from: path)
    let key = Self.bookmarkKey(for: candidateURL)

    return try stateQueue.sync {
      // 1. Exact match
      let directKey = candidateURL.path
      let stdKey = candidateURL.standardizedFileURL.path
      if let bookmarkData = bookmarks[key] ?? bookmarks[directKey] ?? bookmarks[stdKey] {
        let resolved = try resolveBookmarkDataLocked(bookmarkData)
        return (resolved, nil)
      }

      // 2. Upward traversal for ancestor directories
      var current = candidateURL.deletingLastPathComponent()
      while current.path != "/" && !current.path.isEmpty && current.pathComponents.count > 1 {
        let parentKey = Self.bookmarkKey(for: current)
        let parentDirectKey = current.path
        let parentStdKey = current.standardizedFileURL.path
        if let parentBookmarkData = bookmarks[parentKey] ?? bookmarks[parentDirectKey] ?? bookmarks[parentStdKey] {
          if let resolvedParent = try? resolveBookmarkDataLocked(parentBookmarkData) {
            return (candidateURL, resolvedParent)
          }
        }
        let next = current.deletingLastPathComponent()
        if next.path == current.path { break }
        current = next
      }

      return (candidateURL, nil)
    }
  }

  @discardableResult
  func remember(url: URL) -> Bool {
    guard url.isFileURL else { return false }

    return stateQueue.sync {
      rememberLocked(url: url)
    }
  }

  func hasBookmark(for path: String) -> Bool {
    let url = Self.url(from: path)
    let key = Self.bookmarkKey(for: url)
    let directKey = url.path
    let stdKey = url.standardizedFileURL.path
    return stateQueue.sync {
      bookmarks[key] != nil || bookmarks[directKey] != nil || bookmarks[stdKey] != nil
    }
  }

  func hasParentBookmark(for path: String) -> Bool {
    let candidateURL = Self.url(from: path)
    return stateQueue.sync {
      var current = candidateURL.deletingLastPathComponent()
      while current.path != "/" && !current.path.isEmpty && current.pathComponents.count > 1 {
        let parentKey = Self.bookmarkKey(for: current)
        let parentDirectKey = current.path
        let parentStdKey = current.standardizedFileURL.path
        if bookmarks[parentKey] != nil || bookmarks[parentDirectKey] != nil || bookmarks[parentStdKey] != nil {
          return true
        }
        let next = current.deletingLastPathComponent()
        if next.path == current.path { break }
        current = next
      }
      return false
    }
  }

  func storedPaths() -> [String] {
    stateQueue.sync {
      bookmarks.keys.sorted()
    }
  }

  func forget(path: String) {
    let url = Self.url(from: path)
    let key = Self.bookmarkKey(for: url)
    let directKey = url.path
    let stdKey = url.standardizedFileURL.path
    stateQueue.sync {
      bookmarks.removeValue(forKey: key)
      bookmarks.removeValue(forKey: directKey)
      bookmarks.removeValue(forKey: stdKey)
      UserDefaults.standard.set(bookmarks, forKey: storageKey)
    }
  }

  private func resolveBookmarkDataLocked(_ bookmarkData: Data) throws -> URL {
    var isStale = false
    #if os(macOS)
    let resolvedURL = try URL(
      resolvingBookmarkData: bookmarkData,
      options: [.withSecurityScope],
      relativeTo: nil,
      bookmarkDataIsStale: &isStale
    )
    #else
    let resolvedURL = try URL(
      resolvingBookmarkData: bookmarkData,
      options: [.withoutUI],
      relativeTo: nil,
      bookmarkDataIsStale: &isStale
    )
    #endif

    if isStale {
      _ = rememberLocked(url: resolvedURL)
    }

    return resolvedURL
  }

  /// Persists a bookmark for `url`.
  ///
  /// IMPORTANT: `url` must be the original URL returned by the system picker.
  /// Rebuilding it via `standardizedFileURL` / `resolvingSymlinksInPath()`
  /// drops the security-scope token, so the resulting bookmark can never be
  /// started again after the picker session ends.
  private func rememberLocked(url: URL) -> Bool {
    guard url.isFileURL else { return false }

    do {
      let bookmarkData = try Self.createBookmarkData(for: url)
      let key1 = Self.bookmarkKey(for: url)
      let key2 = url.standardizedFileURL.path
      let key3 = url.path
      bookmarks[key1] = bookmarkData
      bookmarks[key2] = bookmarkData
      bookmarks[key3] = bookmarkData
      UserDefaults.standard.set(bookmarks, forKey: storageKey)
      return true
    } catch {
      return false
    }
  }

  /// Creates the persisted bookmark data for `url`.
  ///
  /// `.minimalBookmark` is the only creation option iOS keeps across launches;
  /// an empty option set yields a bookmark that resolves to a plain
  /// (non scoped) URL, and `startAccessingSecurityScopedResource()` then fails
  /// on every later launch.
  private static func createBookmarkData(for url: URL) throws -> Data {
    #if os(macOS)
    return try url.bookmarkData(
      options: [.withSecurityScope],
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )
    #else
    do {
      return try url.bookmarkData(
        options: .minimalBookmark,
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
    } catch {
      return try url.bookmarkData(
        options: [],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
    }
    #endif
  }

  private static func url(from path: String) -> URL {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("file://"), let url = URL(string: trimmed) {
      return url
    }
    return URL(fileURLWithPath: trimmed)
  }

  private static func bookmarkKey(for url: URL) -> String {
    url.standardizedFileURL.resolvingSymlinksInPath().path
  }
}

final class SecurityScopedFileAccessCoordinator {
  private let bookmarkStore = SecurityScopedBookmarkStore()
  private var activeAccessCounts: [String: Int] = [:]
  private var activeAccessURLs: [String: URL] = [:]
  private var startedSecurityScope: [String: Bool] = [:]
  private let stateQueue = DispatchQueue(label: "audio_core.security_scoped_file_access")

  static func isCurrentSandboxPath(_ path: String) -> Bool {
    #if os(iOS)
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    let rawPath = trimmed.hasPrefix("file://")
      ? (URL(string: trimmed)?.standardizedFileURL.resolvingSymlinksInPath().path ?? trimmed)
      : URL(fileURLWithPath: trimmed).standardizedFileURL.resolvingSymlinksInPath().path

    let home = NSHomeDirectory()
    let homePath = URL(fileURLWithPath: home).standardizedFileURL.resolvingSymlinksInPath().path
    if rawPath.hasPrefix(homePath) {
      return true
    }
    if let appGroupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.app.vynody.player") {
      let appGroupPath = appGroupURL.standardizedFileURL.resolvingSymlinksInPath().path
      if rawPath.hasPrefix(appGroupPath) {
        return true
      }
    }
    #endif
    return false
  }

  static func resolveSandboxInternalPath(_ path: String) -> String? {
    #if os(iOS)
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    let rawPath = trimmed.hasPrefix("file://")
      ? (URL(string: trimmed)?.standardizedFileURL.resolvingSymlinksInPath().path ?? trimmed)
      : URL(fileURLWithPath: trimmed).standardizedFileURL.resolvingSymlinksInPath().path

    let home = NSHomeDirectory()
    let homePath = URL(fileURLWithPath: home).standardizedFileURL.resolvingSymlinksInPath().path
    if rawPath.hasPrefix(homePath) {
      return rawPath
    }
    if let appGroupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.app.vynody.player") {
      let appGroupPath = appGroupURL.standardizedFileURL.resolvingSymlinksInPath().path
      if rawPath.hasPrefix(appGroupPath) {
        return rawPath
      }
    }

    // Match any legacy / stale sandbox container UUID for Documents / Library / tmp that exists in current home sandbox
    // ONLY if the rawPath does not exist on disk and candidate exists in current home sandbox.
    if !FileManager.default.fileExists(atPath: rawPath) {
      if let range = rawPath.range(of: #"/Containers/Data/Application/[^/]+/(Documents|Library|tmp)($|/.*)"#, options: .regularExpression) {
        let match = String(rawPath[range])
        if let subRange = match.range(of: #"/(Documents|Library|tmp)($|/.*)"#, options: .regularExpression) {
          let subPath = String(match[subRange])
          let candidate = homePath + subPath
          if FileManager.default.fileExists(atPath: candidate) {
            return candidate
          }
        }
      }
    }
    #endif
    return nil
  }

  private static func isSandboxInternalPath(_ path: String) -> Bool {
    resolveSandboxInternalPath(path) != nil
  }

  func resolveURL(for path: String) throws -> URL {
    if let resolved = Self.resolveSandboxInternalPath(path) {
      return URL(fileURLWithPath: resolved)
    }
    let (url, _) = try bookmarkStore.resolveURL(for: path)
    return url
  }

  func acquireAccess(for path: String) throws -> URL {
    if let resolved = Self.resolveSandboxInternalPath(path) {
      return URL(fileURLWithPath: resolved)
    }

    let (url, parentScopeURL) = try bookmarkStore.resolveURL(for: path)
    _ = retainAccess(for: parentScopeURL ?? url)
    _ = bookmarkStore.remember(url: url)
    return url
  }

  /// Registers persistent access for [path].
  ///
  /// Returns `true` only when the path is actually usable right now. A stored
  /// bookmark that can no longer be started (created without a security scope,
  /// or a File Provider location whose grant was revoked) must not be reported
  /// as success — otherwise the library silently scans zero files.
  @discardableResult
  func registerPersistentAccess(for path: String) -> Bool {
    if Self.isCurrentSandboxPath(path) {
      return true
    }

    if bookmarkStore.hasBookmark(for: path), probeBookmarkAccess(for: path) {
      return true
    }

    // No usable bookmark yet: the path may still be inside the picker's
    // authorization window for this process, so start it before saving.
    let url = URL(fileURLWithPath: path)
    let started = url.startAccessingSecurityScopedResource()
    defer {
      if started {
        url.stopAccessingSecurityScopedResource()
      }
    }
    return bookmarkStore.remember(url: url)
  }

  @discardableResult
  func registerPersistentAccess(for url: URL) -> Bool {
    guard url.isFileURL else { return false }
    if Self.isCurrentSandboxPath(url.path) {
      return true
    }
    // Keep the original URL: any standardization drops the security scope.
    return bookmarkStore.remember(url: url)
  }

  func acquireAccess(for url: URL) -> URL {
    guard url.isFileURL else { return url }
    if let resolved = Self.resolveSandboxInternalPath(url.path) {
      return URL(fileURLWithPath: resolved)
    }

    // Same reason as above: never standardize before starting the scope.
    _ = retainAccess(for: url)
    _ = bookmarkStore.remember(url: url)
    return url
  }

  /// Starts a security-scoped access session for [path].
  ///
  /// Unlike [acquireAccess], the return value is authoritative: it reports
  /// whether the scope is really active, so callers can roll back a root path
  /// that would otherwise scan to zero files.
  @discardableResult
  func beginScopedAccess(for path: String) -> Bool {
    if Self.resolveSandboxInternalPath(path) != nil {
      return true
    }

    guard let (url, parentScopeURL) = try? bookmarkStore.resolveURL(for: path) else {
      return false
    }
    return retainAccess(for: parentScopeURL ?? url)
  }

  /// Starts the scope for `url` and registers the session only when it really
  /// became active.
  ///
  /// A failed attempt is never cached: caches keyed by a failed start would
  /// prevent a later retry (for example right after the user re-picks the
  /// folder) from ever succeeding.
  @discardableResult
  private func retainAccess(for url: URL) -> Bool {
    let key = Self.key(for: url)
    var started = false
    stateQueue.sync {
      if startedSecurityScope[key] == true {
        activeAccessCounts[key, default: 0] += 1
        started = true
        return
      }
      guard url.startAccessingSecurityScopedResource() else { return }
      activeAccessURLs[key] = url
      startedSecurityScope[key] = true
      activeAccessCounts[key, default: 0] += 1
      started = true
    }
    return started
  }

  /// Starts and immediately stops the stored bookmark to verify it still works.
  private func probeBookmarkAccess(for path: String) -> Bool {
    guard let (url, parentScopeURL) = try? bookmarkStore.resolveURL(for: path) else {
      return false
    }
    let target = parentScopeURL ?? url
    let started = target.startAccessingSecurityScopedResource()
    if started {
      target.stopAccessingSecurityScopedResource()
    }
    return started
  }

  func forgetPersistentAccess(for path: String) {
    let key = Self.key(forPath: path)
    stateQueue.sync {
      releaseAllAccessLocked(forKey: key)
    }
    bookmarkStore.forget(path: path)
  }

  func hasPersistentAccess(for path: String) -> Bool {
    if Self.isCurrentSandboxPath(path) {
      return true
    }
    return bookmarkStore.hasBookmark(for: path) || bookmarkStore.hasParentBookmark(for: path)
  }

  func listPersistentAccessPaths() -> [String] {
    bookmarkStore.storedPaths()
  }

  func releaseAccess(for path: String) {
    if Self.isCurrentSandboxPath(path) {
      return
    }
    let key: String
    if let resolved = try? bookmarkStore.resolveURL(for: path) {
      key = Self.key(for: resolved.parentScopeURL ?? resolved.url)
    } else {
      key = Self.key(forPath: path)
    }
    stateQueue.sync {
      releaseAccessLocked(forKey: key)
    }
  }

  func releaseAccess(for url: URL) {
    releaseAccess(for: url.path)
  }

  func releaseAllAccess() {
    stateQueue.sync {
      let keys = Array(activeAccessCounts.keys)
      for key in keys {
        releaseAllAccessLocked(forKey: key)
      }
    }
  }

  func withTemporaryAccess<T>(for path: String, _ body: (URL) throws -> T) throws -> T {
    let url = try acquireAccess(for: path)
    defer { releaseAccess(for: path) }
    return try body(url)
  }

  private func releaseAccessLocked(forKey key: String) {
    guard let count = activeAccessCounts[key] else { return }

    let nextCount = count - 1
    if nextCount > 0 {
      activeAccessCounts[key] = nextCount
      return
    }

    releaseAllAccessLocked(forKey: key)
  }

  private func releaseAllAccessLocked(forKey key: String) {
    if startedSecurityScope[key] == true, let url = activeAccessURLs[key] {
      url.stopAccessingSecurityScopedResource()
    }

    activeAccessCounts[key] = nil
    activeAccessURLs[key] = nil
    startedSecurityScope[key] = nil
  }

  private static func key(for url: URL) -> String {
    url.standardizedFileURL.resolvingSymlinksInPath().path
  }

  private static func key(forPath path: String) -> String {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("file://"), let url = URL(string: trimmed) {
      return key(for: url)
    }
    return key(for: URL(fileURLWithPath: trimmed))
  }
}
