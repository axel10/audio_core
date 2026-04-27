import Foundation

final class SecurityScopedBookmarkStore {
  private let storageKey = "audio_core.securityScopedBookmarks"
  private var bookmarks: [String: Data]

  init() {
    if let stored = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: Data] {
      bookmarks = stored
    } else {
      bookmarks = [:]
    }
  }

  func resolveURL(for path: String) throws -> URL {
    let candidateURL = Self.url(from: path)
    let key = Self.bookmarkKey(for: candidateURL)

    guard let bookmarkData = bookmarks[key] else {
      return candidateURL
    }

    var isStale = false
    let resolvedURL = try URL(
      resolvingBookmarkData: bookmarkData,
      options: [.withSecurityScope],
      relativeTo: nil,
      bookmarkDataIsStale: &isStale
    )

    if isStale {
      remember(url: resolvedURL)
    }

    return resolvedURL
  }

  @discardableResult
  func remember(url: URL) -> Bool {
    guard url.isFileURL else { return false }

    do {
      let bookmarkData = try url.bookmarkData(
        options: [.withSecurityScope],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
      bookmarks[Self.bookmarkKey(for: url)] = bookmarkData
      UserDefaults.standard.set(bookmarks, forKey: storageKey)
      return true
    } catch {
      return false
    }
  }

  func hasBookmark(for path: String) -> Bool {
    let url = Self.url(from: path)
    return bookmarks[Self.bookmarkKey(for: url)] != nil
  }

  func storedPaths() -> [String] {
    bookmarks.keys.sorted()
  }

  func forget(path: String) {
    let key = Self.bookmarkKey(for: Self.url(from: path))
    bookmarks.removeValue(forKey: key)
    UserDefaults.standard.set(bookmarks, forKey: storageKey)
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

  func resolveURL(for path: String) throws -> URL {
    try bookmarkStore.resolveURL(for: path)
  }

  func acquireAccess(for path: String) throws -> URL {
    let url = try resolveURL(for: path)
    let key = Self.key(for: url)

    if activeAccessCounts[key] == nil {
      activeAccessCounts[key] = 0
      activeAccessURLs[key] = url
      startedSecurityScope[key] = url.startAccessingSecurityScopedResource()
    }

    activeAccessCounts[key, default: 0] += 1
    _ = bookmarkStore.remember(url: url)
    return url
  }

  @discardableResult
  func registerPersistentAccess(for path: String) -> Bool {
    do {
      let url = try resolveURL(for: path)
      return bookmarkStore.remember(url: url)
    } catch {
      return false
    }
  }

  func forgetPersistentAccess(for path: String) {
    let key = Self.key(forPath: path)
    releaseAllAccess(forKey: key)
    bookmarkStore.forget(path: path)
  }

  func hasPersistentAccess(for path: String) -> Bool {
    bookmarkStore.hasBookmark(for: path)
  }

  func listPersistentAccessPaths() -> [String] {
    bookmarkStore.storedPaths()
  }

  func releaseAccess(for path: String) {
    let key = Self.key(forPath: path)
    releaseAccess(forKey: key)
  }

  func releaseAccess(for url: URL) {
    releaseAccess(forKey: Self.key(for: url))
  }

  func releaseAllAccess() {
    let keys = Array(activeAccessCounts.keys)
    for key in keys {
      releaseAllAccess(forKey: key)
    }
  }

  func withTemporaryAccess<T>(for path: String, _ body: (URL) throws -> T) throws -> T {
    let url = try acquireAccess(for: path)
    defer { releaseAccess(for: url) }
    return try body(url)
  }

  private func releaseAccess(forKey key: String) {
    guard let count = activeAccessCounts[key] else { return }

    let nextCount = count - 1
    if nextCount > 0 {
      activeAccessCounts[key] = nextCount
      return
    }

    releaseAllAccess(forKey: key)
  }

  private func releaseAllAccess(forKey key: String) {
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
