import Foundation
import AudioToolbox

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
    let bitRate = intValue(request, key: "bitRate")
    let bitRateMode = normalizeBitRateMode(optionalStringValue(request, key: "bitRateMode"))

    guard supportedFormatValues.contains(outputFormat) else {
      throw ConversionError.unsupportedOutputFormat(outputFormat)
    }

    let sourceURL = URL(fileURLWithPath: inputPath)
    let destinationURL = URL(fileURLWithPath: outputPath)

    try createParentDirectoryIfNeeded(for: destinationURL)
    try? FileManager.default.removeItem(at: destinationURL)

    do {
      if let encoder = try makeEncoder(
        destinationURL: destinationURL,
        outputFormat: outputFormat,
        bitRate: bitRate,
        bitRateMode: bitRateMode
      ) {
        try AudioConverter.convert(sourceURL, using: encoder)
      } else {
        try AudioConverter.convert(sourceURL, to: destinationURL)
      }
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
                nsError.domain == "org.sbooth.AudioEngine.AudioFile" ||
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

  private static func normalizeBitRateMode(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func intValue(_ request: [String: Any], key: String) -> Int? {
    guard let value = request[key] as? NSNumber else {
      return nil
    }
    let intValue = value.intValue
    return intValue > 0 ? intValue : nil
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

  private static func optionalStringValue(_ request: [String: Any], key: String) -> String? {
    guard let value = request[key] as? String else {
      return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func makeEncoder(
    destinationURL: URL,
    outputFormat: String,
    bitRate: Int?,
    bitRateMode: String?
  ) throws -> AudioEncoder? {
    let encoder = try createEncoder(destinationURL: destinationURL, outputFormat: outputFormat)
    var settings: [AudioEncodingSettingsKey: Any] = [:]

    switch outputFormat {
    case "m4a", "m4b":
      settings[.coreAudioFileTypeID] = NSNumber(
        value: outputFormat == "m4a" ? UInt32(kAudioFileM4AType) : UInt32(kAudioFileM4BType)
      )
      settings[.coreAudioFormatID] = NSNumber(value: UInt32(kAudioFormatMPEG4AAC))

      if let bitRate {
        settings[.coreAudioAudioConverterPropertySettings] = [
          kAudioConverterEncodeBitRate: NSNumber(value: bitRate),
          kAudioCodecPropertyBitRateControlMode: NSNumber(
            value: bitRateMode == "vbr"
              ? kAudioCodecBitRateControlMode_VariableConstrained
              : kAudioCodecBitRateControlMode_Constant
          ),
        ]
      } else if let bitRateMode {
        settings[.coreAudioAudioConverterPropertySettings] = [
          kAudioCodecPropertyBitRateControlMode: NSNumber(
            value: bitRateMode == "vbr"
              ? kAudioCodecBitRateControlMode_VariableConstrained
              : kAudioCodecBitRateControlMode_Constant
          ),
        ]
      }
    case "aac", "caf":
      guard bitRate != nil || bitRateMode != nil else {
        return nil
      }

      if let bitRate {
        settings[.coreAudioAudioConverterPropertySettings] = [
          kAudioConverterEncodeBitRate: NSNumber(value: bitRate),
          kAudioCodecPropertyBitRateControlMode: NSNumber(
            value: bitRateMode == "vbr"
              ? kAudioCodecBitRateControlMode_VariableConstrained
              : kAudioCodecBitRateControlMode_Constant
          ),
        ]
      } else if let bitRateMode {
        settings[.coreAudioAudioConverterPropertySettings] = [
          kAudioCodecPropertyBitRateControlMode: NSNumber(
            value: bitRateMode == "vbr"
              ? kAudioCodecBitRateControlMode_VariableConstrained
              : kAudioCodecBitRateControlMode_Constant
          ),
        ]
      }
    case "mp3":
      if let bitRate {
        let kilobitsPerSecond = normalizeBitRateForKbps(bitRate)
        if bitRateMode == "vbr" {
          settings[.mp3AverageBitrate] = kilobitsPerSecond
        } else {
          settings[.mp3ConstantBitrate] = kilobitsPerSecond
        }
      } else if bitRateMode == "vbr" {
        settings[.mp3UseVariableBitrate] = true
      }
    case "opus":
      settings[.opusPreserveSampleRate] = true
      if let bitRate {
        settings[.opusBitrate] = normalizeBitRateForKbps(bitRate)
      }
      if let bitRateMode {
        settings[.opusBitrateMode] = switch bitRateMode {
        case "vbr":
          OpusBitrateMode.constrainedVBR
        case "cbr":
          OpusBitrateMode.hardCBR
        default:
          OpusBitrateMode.constrainedVBR
        }
      }
    default:
      return nil
    }

    if !settings.isEmpty {
      encoder.settings = settings
    }
    return encoder
  }

  private static func createEncoder(
    destinationURL: URL,
    outputFormat: String
  ) throws -> AudioEncoder {
    switch outputFormat {
    case "m4a", "m4b", "aac", "caf":
      return try AudioEncoder(url: destinationURL)
    case "mp3":
      return try AudioEncoder(url: destinationURL, encoderName: .MP3)
    case "opus":
      return try AudioEncoder(url: destinationURL, encoderName: .oggOpus)
    default:
      return try AudioEncoder(url: destinationURL)
    }
  }

  private static func normalizeBitRateForKbps(_ bitRate: Int) -> Int {
    if bitRate <= 1000 {
      return max(1, bitRate)
    }
    return max(1, (bitRate + 500) / 1000)
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
