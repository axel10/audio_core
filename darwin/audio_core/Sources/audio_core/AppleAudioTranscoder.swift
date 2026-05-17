import Foundation

import SFBAudioEngine

enum AppleAudioTranscoder {
  private static let engineName = "SFBAudioEngine"
  private static let supportedFormatValues: [String] = [
    "aac",
    "alac",
    "aiff",
    "caf",
    "flac",
    "m4a",
    "m4b",
    "mp3",
    "ogg",
    "opus",
    "wav",
  ]

  static func capabilities() -> [String: Any] {
    let supportedOutputFormats = supportedFormatValues.filter {
      AudioEncoder.handlesPaths(withExtension: $0)
    }

    return [
      "engine": engineName,
      "supportedOutputFormats": supportedOutputFormats,
      "supportsProgress": false,
      "supportsCancellation": false,
      "requiresExternalBinary": false,
      "notes": "Uses SFBAudioEngine on Apple platforms. Progress reporting is coarse, and request-level bitrate/sample-rate tuning is not wired yet.",
    ]
  }

  static func convert(request: [String: Any]) -> [String: Any] {
    do {
      return try convertThrowing(request: request)
    } catch {
      return failureResult(request: request, error: error)
    }
  }

  private static func convertThrowing(request: [String: Any]) throws -> [String: Any] {
    let inputPath = try stringValue(request, key: "inputPath")
    let outputPath = try stringValue(request, key: "outputPath")
    let outputFormat = normalizeFormat(try stringValue(request, key: "outputFormat"))

    guard supportedFormatValues.contains(outputFormat) else {
      throw ConversionError.unsupportedOutputFormat(outputFormat)
    }

    let sourceURL = URL(fileURLWithPath: inputPath)
    let destinationURL = URL(fileURLWithPath: outputPath)

    try createParentDirectoryIfNeeded(for: destinationURL)
    try? FileManager.default.removeItem(at: destinationURL)

    do {
      try AudioConverter.convert(sourceURL, to: destinationURL)
    } catch {
      try? FileManager.default.removeItem(at: destinationURL)
      throw error
    }

    return [
      "success": true,
      "command": "AudioConverter.convert(\"\(inputPath)\" -> \"\(outputPath)\")",
      "outputPath": outputPath,
      "engine": engineName,
      "outputFormat": outputFormat,
      "errorCode": NSNull(),
      "errorMessage": NSNull(),
      "stdout": NSNull(),
      "stderr": NSNull(),
      "rawLog": NSNull(),
    ]
  }

  private static func failureResult(request: [String: Any], error: Error) -> [String: Any] {
    let outputFormat = normalizeFormat((request["outputFormat"] as? String) ?? "")
    let errorCode: String
    let errorMessage: String

    if let conversionError = error as? ConversionError {
      errorCode = conversionError.code
      errorMessage = conversionError.localizedDescription
    } else if let nsError = error as NSError?,
              nsError.domain == AudioConverter.ErrorDomain ||
                nsError.domain == AudioEncoder.ErrorDomain ||
                nsError.domain == AudioFile.ErrorDomain ||
                nsError.domain == OutputTarget.ErrorDomain {
      errorCode = "conversion_failed"
      errorMessage = nsError.localizedDescription
    } else {
      errorCode = "conversion_failed"
      errorMessage = error.localizedDescription
    }

    return [
      "success": false,
      "command": NSNull(),
      "outputPath": NSNull(),
      "engine": engineName,
      "outputFormat": outputFormat.isEmpty ? NSNull() : outputFormat,
      "errorCode": errorCode,
      "errorMessage": errorMessage,
      "stdout": NSNull(),
      "stderr": NSNull(),
      "rawLog": NSNull(),
    ]
  }

  private static func createParentDirectoryIfNeeded(for url: URL) throws {
    let parentDirectory = url.deletingLastPathComponent()
    guard !parentDirectory.path.isEmpty else { return }
    try FileManager.default.createDirectory(
      at: parentDirectory,
      withIntermediateDirectories: true,
      attributes: nil
    )
  }

  private static func normalizeFormat(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private static func stringValue(_ request: [String: Any], key: String) throws -> String {
    guard let value = request[key] as? String else {
      throw ConversionError.invalidRequest("Missing required field: \(key)")
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw ConversionError.invalidRequest("Missing required field: \(key)")
    }
    return trimmed
  }
}

private enum ConversionError: LocalizedError {
  case invalidRequest(String)
  case unsupportedOutputFormat(String)

  var code: String {
    switch self {
    case .invalidRequest:
      return "invalid_request"
    case .unsupportedOutputFormat:
      return "unsupported_output_format"
    }
  }

  var errorDescription: String? {
    switch self {
    case .invalidRequest(let message):
      return message
    case .unsupportedOutputFormat(let format):
      return "Output format '\(format)' is not supported by SFBAudioEngine on this platform."
    }
  }
}
