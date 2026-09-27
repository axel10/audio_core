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
      if let bookmarkData = bookmarks[key] {
        let resolved = try resolveBookmarkDataLocked(bookmarkData)
        return (resolved, nil)
      }

      // 2. Upward traversal for ancestor directories
      var current = candidateURL.deletingLastPathComponent()
      while current.path != "/" && !current.path.isEmpty && current.pathComponents.count > 1 {
        let parentKey = Self.bookmarkKey(for: current)
        if let parentBookmarkData = bookmarks[parentKey] {
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
    return stateQueue.sync {
      bookmarks[Self.bookmarkKey(for: url)] != nil
    }
  }

  func hasParentBookmark(for path: String) -> Bool {
    let candidateURL = Self.url(from: path)
    return stateQueue.sync {
      var current = candidateURL.deletingLastPathComponent()
      while current.path != "/" && !current.path.isEmpty && current.pathComponents.count > 1 {
        let parentKey = Self.bookmarkKey(for: current)
        if bookmarks[parentKey] != nil {
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
    let key = Self.bookmarkKey(for: Self.url(from: path))
    stateQueue.sync {
      bookmarks.removeValue(forKey: key)
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
      options: [],
      relativeTo: nil,
      bookmarkDataIsStale: &isStale
    )
    #endif

    if isStale {
      _ = rememberLocked(url: resolvedURL)
    }

    return resolvedURL
  }

  private func rememberLocked(url: URL) -> Bool {
    guard url.isFileURL else { return false }

    do {
      #if os(macOS)
      let bookmarkData = try url.bookmarkData(
        options: [.withSecurityScope],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
      #else
      let bookmarkData = try url.bookmarkData(
        options: [],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
      #endif
      bookmarks[Self.bookmarkKey(for: url)] = bookmarkData
      UserDefaults.standard.set(bookmarks, forKey: storageKey)
      return true
    } catch {
      return false
    }
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

  func resolveURL(for path: String) throws -> URL {
    let (url, _) = try bookmarkStore.resolveURL(for: path)
    return url
  }

  func acquireAccess(for path: String) throws -> URL {
    let (url, parentScopeURL) = try bookmarkStore.resolveURL(for: path)

    stateQueue.sync {
      if let parentURL = parentScopeURL {
        let parentKey = Self.key(for: parentURL)
        if activeAccessCounts[parentKey] == nil {
          activeAccessCounts[parentKey] = 0
          activeAccessURLs[parentKey] = parentURL
          startedSecurityScope[parentKey] = parentURL.startAccessingSecurityScopedResource()
        }
        activeAccessCounts[parentKey, default: 0] += 1
      }

      let key = Self.key(for: url)
      if activeAccessCounts[key] == nil {
        activeAccessCounts[key] = 0
        activeAccessURLs[key] = url
        startedSecurityScope[key] = url.startAccessingSecurityScopedResource()
      }

      activeAccessCounts[key, default: 0] += 1
    }

    _ = bookmarkStore.remember(url: url)
    return url
  }

  @discardableResult
  func registerPersistentAccess(for path: String) -> Bool {
    do {
      let (url, parentScopeURL) = try bookmarkStore.resolveURL(for: path)
      if let parentURL = parentScopeURL {
        let parentStarted = parentURL.startAccessingSecurityScopedResource()
        defer {
          if parentStarted {
            parentURL.stopAccessingSecurityScopedResource()
          }
        }
        return bookmarkStore.remember(url: url)
      }
      return bookmarkStore.remember(url: url)
    } catch {
      return false
    }
  }

  func forgetPersistentAccess(for path: String) {
    let key = Self.key(forPath: path)
    stateQueue.sync {
      releaseAllAccessLocked(forKey: key)
    }
    bookmarkStore.forget(path: path)
  }

  func hasPersistentAccess(for path: String) -> Bool {
    bookmarkStore.hasBookmark(for: path) || bookmarkStore.hasParentBookmark(for: path)
  }

  func listPersistentAccessPaths() -> [String] {
    bookmarkStore.storedPaths()
  }

  func releaseAccess(for path: String) {
    let key = Self.key(forPath: path)
    stateQueue.sync {
      releaseAccessLocked(forKey: key)
    }
  }

  func releaseAccess(for url: URL) {
    let key = Self.key(for: url)
    stateQueue.sync {
      releaseAccessLocked(forKey: key)
    }
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
    defer { releaseAccess(for: url) }
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
