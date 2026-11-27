#if os(iOS)
import Foundation
import MediaPlayer

final class IosMediaLibraryService {
  static let shared = IosMediaLibraryService()

  private init() {}

  func hasPermission() -> Bool {
    return MPMediaLibrary.authorizationStatus() == .authorized
  }

  func ensurePermission(completion: @escaping (Bool) -> Void) {
    let status = MPMediaLibrary.authorizationStatus()
    switch status {
    case .authorized:
      completion(true)
    case .notDetermined:
      MPMediaLibrary.requestAuthorization { newStatus in
        DispatchQueue.main.async {
          completion(newStatus == .authorized)
        }
      }
    case .denied, .restricted:
      completion(false)
    @unknown default:
      completion(false)
    }
  }

  func scanAudioLibrary() -> [[String: Any]] {
    let query = MPMediaQuery.songs()
    guard let items = query.items else {
      return []
    }

    var results: [[String: Any]] = []
    results.reserveCapacity(items.count)

    for item in items {
      // Skip DRM-protected tracks and cloud-only tracks not downloaded locally.
      if item.hasProtectedAsset {
        continue
      }
      guard let assetURL = item.assetURL else {
        continue
      }

      var entry: [String: Any] = [
        "id": String(item.persistentID),
        "uri": assetURL.absoluteString,
        "title": (item.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
          ? item.title!
          : "Unknown title",
        "durationMs": Int((item.playbackDuration * 1000.0).rounded()),
      ]

      if let artist = item.artist, !artist.isEmpty {
        entry["artist"] = artist
      }
      if let album = item.albumTitle, !album.isEmpty {
        entry["album"] = album
      }
      if let albumArtist = item.albumArtist, !albumArtist.isEmpty {
        entry["albumArtist"] = albumArtist
      }
      if let genre = item.genre, !genre.isEmpty {
        entry["genre"] = genre
      }
      if item.albumTrackNumber > 0 {
        entry["trackNumber"] = item.albumTrackNumber
      }
      if item.discNumber > 0 {
        entry["discNumber"] = item.discNumber
      }

      results.append(entry)
    }

    return results
  }

  func extractArtwork(persistentId: String, maxSize: Int) -> Data? {
    guard let numericId = UInt64(persistentId) else {
      return nil
    }
    let predicate = MPMediaPropertyPredicate(
      value: NSNumber(value: numericId),
      forProperty: MPMediaItemPropertyPersistentID
    )
    let query = MPMediaQuery.songs()
    query.addFilterPredicate(predicate)
    guard let item = query.items?.first,
          let artwork = item.artwork else {
      return nil
    }
    let targetSize = CGSize(width: maxSize, height: maxSize)
    guard let image = artwork.image(at: targetSize) else {
      return nil
    }
    return image.jpegData(compressionQuality: 0.85)
  }
}
#endif
