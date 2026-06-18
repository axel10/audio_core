import Foundation
import ImageIO
import UniformTypeIdentifiers

import SFBAudioEngine

enum AppleTrackMetadataBridge {
  static func readTrackMetadata(path: String, fileAccess: SecurityScopedFileAccessCoordinator) -> [String: Any] {
    do {
      return try fileAccess.withTemporaryAccess(for: path) { url in
        let audioFile = try AudioFile(readingPropertiesAndMetadataFrom: url)
        return metadataPayload(from: audioFile.metadata, fileURL: url)
      }
    } catch {
      return Self.emptyMetadataPayload()
    }
  }

  static func updateTrackMetadata(
    path: String,
    metadata: [String: Any],
    fileAccess: SecurityScopedFileAccessCoordinator
  ) throws {
    try fileAccess.withTemporaryAccess(for: path) { url in
      let audioFile = try AudioFile(readingPropertiesAndMetadataFrom: url)
      apply(metadata: metadata, to: audioFile.metadata)
      try audioFile.writeMetadata()
    }
  }

  static func removeAllTags(
    path: String,
    fileAccess: SecurityScopedFileAccessCoordinator
  ) throws {
    try fileAccess.withTemporaryAccess(for: path) { url in
      let audioFile = try AudioFile(readingPropertiesAndMetadataFrom: url)
      audioFile.metadata.removeAll()
      try audioFile.writeMetadata()
    }
  }

  static func readAudioDetails(
    path: String,
    fileAccess: SecurityScopedFileAccessCoordinator
  ) -> [String: Any]? {
    do {
      return try fileAccess.withTemporaryAccess(for: path) { url in
        let audioFile = try AudioFile(readingPropertiesAndMetadataFrom: url)
        let properties = audioFile.properties
        
        let fileManager = FileManager.default
        let attrs = try fileManager.attributesOfItem(atPath: url.path)
        let fileSize = attrs[.size] as? Int64 ?? 0
        
        let duration = properties.duration
        let sampleRate = Int(properties.sampleRate)
        let channelCount = Int(properties.channelCount)
        
        let bitrate: Int
        if duration > 0 {
          bitrate = Int((Double(fileSize) * 8.0 / duration).rounded())
        } else {
          bitrate = 0
        }
        
        let fileExtension = url.pathExtension.lowercased()
        var formatName = fileExtension
        if fileExtension == "mpeg" {
          formatName = "mp3"
        } else if fileExtension == "mp4" {
          formatName = "m4a"
        }
        
        var codecName = fileExtension
        if fileExtension == "mpeg" {
          codecName = "mp3"
        } else if fileExtension == "mp4" {
          codecName = "aac"
        }
        
        return [
          "formatName": formatName,
          "codecName": codecName,
          "durationMs": Int((duration * 1000.0).rounded()),
          "bitrate": bitrate,
          "sampleRate": sampleRate,
          "channels": channelCount,
          "bitrateMode": "unknown",
          "fileSize": fileSize
        ]
      }
    } catch {
      return nil
    }
  }


  private static func apply(metadata request: [String: Any], to metadata: AudioMetadata) {
    if let value = stringValue(request, key: "title") {
      metadata.title = value
    }
    if let value = stringValue(request, key: "artist") {
      metadata.artist = value
    }
    if let value = stringValue(request, key: "album") {
      metadata.albumTitle = value
    }
    if let value = stringValue(request, key: "albumArtist") {
      metadata.albumArtist = value
    }
    if request.keys.contains("trackNumber") {
      metadata.trackNumber = intValue(request, key: "trackNumber")
    }
    if request.keys.contains("trackTotal") {
      metadata.trackTotal = intValue(request, key: "trackTotal")
    }
    if request.keys.contains("discNumber") {
      metadata.discNumber = intValue(request, key: "discNumber")
    }
    if let value = stringValue(request, key: "date") {
      metadata.releaseDate = value
    } else if request.keys.contains("year") {
      if let year = intValue(request, key: "year") {
        metadata.releaseDate = String(year)
      } else if request["year"] is NSNull {
        metadata.releaseDate = nil
      }
    }
    if let value = stringValue(request, key: "comment") {
      metadata.comment = value
    }
    if let value = stringValue(request, key: "lyrics") {
      metadata.lyrics = value
    }
    if let value = stringValue(request, key: "composer") {
      metadata.composer = value
    }
    if request.keys.contains("genres") {
      let genres = stringArrayValue(request, key: "genres")
      metadata.genre = genres?.first
    }

    var additionalMetadata = (metadata.additionalMetadata as? [String: Any]) ?? [:]
    updateAdditionalMetadata(
      &additionalMetadata,
      request: request,
      key: "lyricist",
      storageKey: "LYRICIST"
    )
    updateAdditionalMetadata(
      &additionalMetadata,
      request: request,
      key: "performer",
      storageKey: "PERFORMER"
    )
    updateAdditionalMetadata(
      &additionalMetadata,
      request: request,
      key: "conductor",
      storageKey: "CONDUCTOR"
    )
    updateAdditionalMetadata(
      &additionalMetadata,
      request: request,
      key: "remixer",
      storageKey: "REMIXER"
    )

    if let pictures = pictureArrayValue(request, key: "pictures") {
      metadata.removeAllAttachedPictures()
      for picture in pictures {
        metadata.attachPicture(
          AttachedPicture(
            imageData: picture.bytes,
            type: picture.type,
            description: picture.description
          )
        )
      }
    }

    if additionalMetadata.isEmpty {
      metadata.additionalMetadata = nil
    } else {
      metadata.additionalMetadata = additionalMetadata
    }
  }

  private static func metadataPayload(from metadata: AudioMetadata, fileURL: URL) -> [String: Any] {
    var payload: [String: Any] = [:]

    if let value = normalizedString(metadata.title) {
      payload["title"] = value
    }
    if let value = normalizedString(metadata.artist) {
      payload["artist"] = value
    }
    if let value = normalizedString(metadata.albumTitle) {
      payload["album"] = value
    }
    if let value = normalizedString(metadata.albumArtist) {
      payload["albumArtist"] = value
    }
    if let value = metadata.trackNumber {
      payload["trackNumber"] = value
    }
    if let value = metadata.trackTotal {
      payload["trackTotal"] = value
    }
    if let value = metadata.discNumber {
      payload["discNumber"] = value
    }
    if let value = normalizedString(metadata.releaseDate) {
      payload["date"] = value
      if let year = yearFromDateString(value) {
        payload["year"] = year
      }
    }
    if let value = normalizedString(metadata.comment) {
      payload["comment"] = value
    }
    if let value = normalizedString(metadata.lyrics) {
      payload["lyrics"] = value
    }
    if let value = normalizedString(metadata.composer) {
      payload["composer"] = value
    }
    if let value = stringFromAdditionalMetadata(metadata, keys: ["LYRICIST", "Lyricist", "TEXT"]) {
      payload["lyricist"] = value
    }
    if let value = stringFromAdditionalMetadata(metadata, keys: ["PERFORMER", "Performer", "ARTIST"]) {
      payload["performer"] = value
    }
    if let value = stringFromAdditionalMetadata(metadata, keys: ["CONDUCTOR", "Conductor"]) {
      payload["conductor"] = value
    }
    if let value = stringFromAdditionalMetadata(metadata, keys: ["REMIXER", "Remixer"]) {
      payload["remixer"] = value
    }

    if let genre = normalizedString(metadata.genre) {
      payload["genres"] = [genre]
    } else {
      payload["genres"] = [String]()
    }

    payload["pictures"] = metadata.attachedPictures
      .compactMap { picture -> [String: Any]? in
        let imageData = picture.imageData
        return [
          "bytes": imageData,
          "mimeType": mimeType(for: imageData),
          "pictureType": pictureTypeLabel(for: picture.type),
          "description": normalizedString(picture.description) as Any,
        ].compactMapValues { $0 }
      }

    payload["metadataType"] = "apple-native"
    payload["raw"] = [
      "filePath": fileURL.path,
    ]

    return payload
  }

  private static func emptyMetadataPayload() -> [String: Any] {
    [
      "genres": [String](),
      "pictures": [String](),
      "metadataType": "apple-native",
    ]
  }

  private static func updateAdditionalMetadata(
    _ additionalMetadata: inout [String: Any],
    request: [String: Any],
    key: String,
    storageKey: String
  ) {
    guard request.keys.contains(key) else { return }
    if let value = stringValue(request, key: key) {
      additionalMetadata[storageKey] = value
    } else {
      additionalMetadata.removeValue(forKey: storageKey)
    }
  }

  private static func pictureArrayValue(
    _ request: [String: Any],
    key: String
  ) -> [TrackPictureInput]? {
    guard request.keys.contains(key) else { return nil }
    guard let rawValue = request[key] else { return [] }
    if rawValue is NSNull {
      return []
    }
    guard let values = rawValue as? [Any] else { return [] }

    let pictures = values.compactMap { entry -> TrackPictureInput? in
      if let map = entry as? [String: Any] {
        return pictureInput(from: map)
      }
      return nil
    }
    return pictures
  }

  private static func pictureInput(from map: [String: Any]) -> TrackPictureInput? {
    guard let bytes = dataValue(map["bytes"]) else { return nil }
    return TrackPictureInput(
      bytes: bytes,
      mimeType: stringValue(map, key: "mimeType") ?? "image/jpeg",
      type: pictureType(from: stringValue(map, key: "pictureType")),
      description: stringValue(map, key: "description")
    )
  }

  private static func dataValue(_ value: Any?) -> Data? {
    if let data = value as? Data {
      return data
    }
    if let data = value as? NSData {
      return data as Data
    }
    if let bytes = value as? [UInt8] {
      return Data(bytes)
    }
    if let bytes = value as? [Int] {
      return Data(bytes.map { UInt8(clamping: $0) })
    }
    return nil
  }

  private static func pictureType(from value: String?) -> AttachedPicture.`Type` {
    guard let value else { return .other }

    switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "front cover", "cover front", "front":
      return .frontCover
    case "back cover", "cover back", "back":
      return .backCover
    case "leaflet page", "leaflet":
      return .leafletPage
    case "media label cd", "media":
      return .media
    case "lead artist":
      return .leadArtist
    case "artist / performer", "artist", "performer":
      return .artist
    case "conductor":
      return .conductor
    case "band logo", "band":
      return .band
    case "composer":
      return .composer
    case "lyricist":
      return .lyricist
    case "recording location":
      return .recordingLocation
    case "during recording":
      return .duringRecording
    case "during performance":
      return .duringPerformance
    case "screen capture":
      return .movieScreenCapture
    case "bright fish":
      return .colouredFish
    case "illustration":
      return .illustration
    case "publisher logo":
      return .publisherLogo
    case "icon":
      return .fileIcon
    case "other icon":
      return .otherFileIcon
    default:
      return .other
    }
  }

  private static func pictureTypeLabel(for type: AttachedPicture.`Type`) -> String {
    switch type {
    case .other:
      return "Other"
    case .fileIcon:
      return "Icon"
    case .otherFileIcon:
      return "Other Icon"
    case .frontCover:
      return "Front Cover"
    case .backCover:
      return "Back Cover"
    case .leafletPage:
      return "Leaflet Page"
    case .media:
      return "Media Label CD"
    case .leadArtist:
      return "Lead Artist"
    case .artist:
      return "Artist / Performer"
    case .conductor:
      return "Conductor"
    case .band:
      return "Band Logo"
    case .composer:
      return "Composer"
    case .lyricist:
      return "Lyricist"
    case .recordingLocation:
      return "Recording Location"
    case .duringRecording:
      return "During Recording"
    case .duringPerformance:
      return "During Performance"
    case .movieScreenCapture:
      return "Screen Capture"
    case .colouredFish:
      return "Bright Fish"
    case .illustration:
      return "Illustration"
    case .publisherLogo:
      return "Publisher Logo"
    default:
      return "Other"
    }
  }

  private static func mimeType(for imageData: Data) -> String {
    guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
          let typeIdentifier = CGImageSourceGetType(source) as String? else {
      return "image/jpeg"
    }
    return UTType(typeIdentifier)?.preferredMIMEType ?? "image/jpeg"
  }

  private static func normalizedString(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func stringValue(_ request: [String: Any], key: String) -> String? {
    guard let rawValue = request[key], !(rawValue is NSNull) else { return nil }
    if let value = rawValue as? String {
      return normalizedString(value)
    }
    return nil
  }

  private static func intValue(_ request: [String: Any], key: String) -> Int? {
    guard let rawValue = request[key], !(rawValue is NSNull) else { return nil }
    if let value = rawValue as? Int {
      return value
    }
    if let value = rawValue as? Double {
      return Int(value)
    }
    if let value = rawValue as? NSNumber {
      return value.intValue
    }
    return nil
  }

  private static func intNumberValue(_ request: [String: Any], key: String) -> NSNumber? {
    guard let value = intValue(request, key: key) else { return nil }
    return NSNumber(value: value)
  }

  private static func stringArrayValue(_ request: [String: Any], key: String) -> [String]? {
    guard let rawValue = request[key], !(rawValue is NSNull) else { return [] }
    guard let values = rawValue as? [Any] else { return [] }
    let strings = values.compactMap { entry -> String? in
      if let value = entry as? String {
        return normalizedString(value)
      }
      return nil
    }
    return strings
  }

  private static func stringFromAdditionalMetadata(
    _ metadata: AudioMetadata,
    keys: [String]
  ) -> String? {
    guard let additionalMetadata = metadata.additionalMetadata as? [String: Any] else {
      return nil
    }
    for key in keys {
      if let value = additionalMetadata[key] as? String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
          return trimmed
        }
      }
    }
    return nil
  }

  private static func yearFromDateString(_ value: String) -> Int? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= 4 else { return nil }
    let prefix = trimmed.prefix(4)
    return Int(prefix)
  }

  private struct TrackPictureInput {
    let bytes: Data
    let mimeType: String
    let type: AttachedPicture.`Type`
    let description: String?
  }
}
