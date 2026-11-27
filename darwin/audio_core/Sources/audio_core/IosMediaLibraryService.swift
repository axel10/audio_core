#if os(iOS)
import AVFoundation
import CoreMedia
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

  func extractAudioDetails(assetURLString: String) -> [String: Any]? {
    guard let assetURL = URL(string: assetURLString), assetURL.scheme == "ipod-library" else {
      return nil
    }

    let asset = AVURLAsset(url: assetURL)
    guard let track = asset.tracks(withMediaType: .audio).first else {
      return nil
    }

    var sampleRate = 0
    var channels = 0
    var bitDepth: Int?
    var formatId: AudioFormatID = 0

    if let formatDescs = track.formatDescriptions as? [CMFormatDescription],
       let firstDesc = formatDescs.first,
       let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(firstDesc)?.pointee {
      formatId = asbd.mFormatID
      if asbd.mSampleRate.isFinite && asbd.mSampleRate > 0 {
        sampleRate = Int(asbd.mSampleRate.rounded())
      }
      if asbd.mChannelsPerFrame > 0 {
        channels = Int(asbd.mChannelsPerFrame)
      }
      if asbd.mBitsPerChannel > 0 {
        bitDepth = Int(asbd.mBitsPerChannel)
      } else if formatId == kAudioFormatAppleLossless {
        switch asbd.mFormatFlags {
        case kAppleLosslessFormatFlag_16BitSourceData:
          bitDepth = 16
        case kAppleLosslessFormatFlag_20BitSourceData:
          bitDepth = 20
        case kAppleLosslessFormatFlag_24BitSourceData:
          bitDepth = 24
        case kAppleLosslessFormatFlag_32BitSourceData:
          bitDepth = 32
        default:
          break
        }
      }
    }

    let ext = assetURL.pathExtension.lowercased()
    var formatName = ""
    var codecName = ""

    switch formatId {
    case kAudioFormatMPEG4AAC,
         kAudioFormatMPEG4AAC_HE,
         kAudioFormatMPEG4AAC_HE_V2,
         kAudioFormatMPEG4AAC_LD,
         kAudioFormatMPEG4AAC_ELD,
         kAudioFormatMPEG4AAC_Spatial:
      formatName = "m4a"
      codecName = "aac"
    case kAudioFormatAppleLossless:
      formatName = "m4a"
      codecName = "alac"
    case kAudioFormatMPEGLayer3, kAudioFormatMPEGLayer1, kAudioFormatMPEGLayer2:
      formatName = "mp3"
      codecName = "mp3"
    case kAudioFormatLinearPCM:
      formatName = (ext == "aif" || ext == "aiff") ? "aiff" : "wav"
      codecName = "pcm"
    case kAudioFormatFLAC:
      formatName = "flac"
      codecName = "flac"
    case kAudioFormatOpus:
      formatName = "opus"
      codecName = "opus"
    default:
      if !ext.isEmpty {
        formatName = (ext == "mpeg") ? "mp3" : (ext == "mp4" ? "m4a" : ext)
        if ext == "mp3" || ext == "mpeg" {
          codecName = "mp3"
        } else if ext == "m4a" || ext == "mp4" {
          codecName = "aac"
        } else {
          codecName = formatName
        }
      }
    }

    let estimatedRate = track.estimatedDataRate
    let bitrate = (estimatedRate.isFinite && estimatedRate > 0)
      ? Int(estimatedRate.rounded())
      : 0

    let durationSeconds = CMTimeGetSeconds(asset.duration)
    let durationMs = (durationSeconds.isFinite && durationSeconds > 0)
      ? Int((durationSeconds * 1000.0).rounded())
      : 0

    var result: [String: Any] = [
      "formatName": formatName,
      "codecName": codecName,
      "durationMs": durationMs,
      "bitrate": bitrate,
      "sampleRate": sampleRate,
      "channels": channels,
    ]
    if let bitDepth = bitDepth, bitDepth > 0 {
      result["bitDepth"] = bitDepth
    }
    return result
  }
}
#endif
