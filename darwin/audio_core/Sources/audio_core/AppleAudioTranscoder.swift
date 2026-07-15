import Foundation
import AVFoundation

enum AppleAudioTranscoder {
  private static let engineName = "AVFoundation"
  private static let supportedFormatValues: [String] = [
    "aac",
    "m4a",
    "m4b"
  ]

  static func capabilities() -> [String: Any] {
    return [
      "engine": engineName,
      "supportedOutputFormats": supportedFormatValues,
      "supportsProgress": false,
      "supportsCancellation": false,
      "requiresExternalBinary": false,
      "notes": "Uses native AVFoundation for AAC/M4A/M4B transcoding.",
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

    guard supportedFormatValues.contains(outputFormat) else {
      throw ConversionError.unsupportedOutputFormat(outputFormat)
    }

    let sourceURL = URL(fileURLWithPath: inputPath)
    let destinationURL = URL(fileURLWithPath: outputPath)

    try createParentDirectoryIfNeeded(for: destinationURL)
    try? FileManager.default.removeItem(at: destinationURL)

    if inputPath.hasSuffix(".pcm") {
      let channels = intValue(request, key: "channels") ?? 2
      let sampleRate = intValue(request, key: "sampleRate") ?? 44100
      let targetBitrate = bitRate ?? 128000
      
      let outputSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: channels,
        AVEncoderBitRateKey: targetBitrate
      ]
      
      let audioFile = try AVAudioFile(forWriting: destinationURL, settings: outputSettings)
      
      guard let inputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: Double(sampleRate),
        channels: AVAudioChannelCount(channels),
        interleaved: true
      ) else {
        throw NSError(domain: "AppleAudioTranscoder", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create AVAudioFormat"])
      }
      
      let fileHandle = try FileHandle(forReadingFrom: sourceURL)
      defer {
        try? fileHandle.close()
      }
      
      let bufferSize = 4096 * channels
      let byteBufferSize = bufferSize * 2
      let pcmBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(bufferSize))!
      
      while true {
        let data: Data
        if #available(iOS 13.4, macOS 10.15.4, *) {
          if let d = try fileHandle.read(upToCount: byteBufferSize) {
            data = d
          } else {
            break
          }
        } else {
          let d = fileHandle.readData(ofLength: byteBufferSize)
          if d.isEmpty {
            break
          }
          data = d
        }
        
        if data.isEmpty {
          break
        }
        
        let bytesRead = data.count
        let framesRead = bytesRead / (2 * channels)
        pcmBuffer.frameLength = AVAudioFrameCount(framesRead)
        
        if let int16ChannelData = pcmBuffer.int16ChannelData {
          data.withUnsafeBytes { rawBufferPointer in
            if let srcBase = rawBufferPointer.baseAddress {
              memcpy(int16ChannelData[0], srcBase, bytesRead)
            }
          }
        }
        
        try audioFile.write(from: pcmBuffer)
      }
      
      return [
        "success": true,
        "command": "AVAudioFile+AVAudioConverter(\"\(inputPath)\" -> \"\(outputPath)\")",
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

    // AVAssetReader + AVAssetWriter transcoding loop
    let asset = AVAsset(url: sourceURL)
    
    // Use DispatchSemaphore to wait for loading tracks
    let semaphore = DispatchSemaphore(value: 0)
    var loadError: Error?
    var audioTracks: [AVAssetTrack] = []
    
    asset.loadValuesAsynchronously(forKeys: ["tracks"]) {
      var error: NSError?
      let status = asset.statusOfValue(forKey: "tracks", error: &error)
      if status == .loaded {
        audioTracks = asset.tracks(withMediaType: .audio)
      } else {
        loadError = error
      }
      semaphore.signal()
    }
    _ = semaphore.wait(timeout: .distantFuture)
    
    if let error = loadError {
      throw error
    }
    
    guard let track = audioTracks.first else {
      throw ConversionError.noAudioTrack
    }

    let reader = try AVAssetReader(asset: asset)
    let readerOutputSettings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false
    ]
    let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: readerOutputSettings)
    reader.add(readerOutput)

    let writer = try AVAssetWriter(outputURL: destinationURL, fileType: .m4a)
    
    var channels = 2
    var sampleRate = 44100.0
    
    // Try to get channel and sample rate from track format description
    if let formatDesc = track.formatDescriptions.first {
      let audioDesc = formatDesc as! CMFormatDescription
      if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(audioDesc)?.pointee {
        channels = Int(asbd.mChannelsPerFrame)
        sampleRate = asbd.mSampleRate
      }
    }
    
    let targetBitrate = bitRate ?? 128000
    let writerInputSettings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVNumberOfChannelsKey: channels,
      AVSampleRateKey: sampleRate,
      AVEncoderBitRateKey: targetBitrate
    ]
    let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: writerInputSettings)
    writerInput.expectsMediaDataInRealTime = false
    writer.add(writerInput)

    guard reader.startReading() else {
      throw reader.error ?? ConversionError.readerStartFailed
    }
    guard writer.startWriting() else {
      throw writer.error ?? ConversionError.writerStartFailed
    }
    writer.startSession(atSourceTime: .zero)

    let transcodeSemaphore = DispatchSemaphore(value: 0)
    var transcodeError: Error?

    writerInput.requestMediaDataWhenReady(on: DispatchQueue(label: "audio_core.transcoder.write")) {
      while writerInput.isReadyForMoreMediaData {
        if let sampleBuffer = readerOutput.copyNextSampleBuffer() {
          if !writerInput.append(sampleBuffer) {
            transcodeError = writer.error
            reader.cancelReading()
            transcodeSemaphore.signal()
            return
          }
        } else {
          writerInput.markAsFinished()
          writer.finishWriting {
            if writer.status != .completed {
              transcodeError = writer.error
            }
            transcodeSemaphore.signal()
          }
          break
        }
      }
    }
    
    _ = transcodeSemaphore.wait(timeout: .distantFuture)
    
    if let error = transcodeError {
      try? FileManager.default.removeItem(at: destinationURL)
      throw error
    }

    return [
      "success": true,
      "command": "AVAssetReader+AVAssetWriter(\"\(inputPath)\" -> \"\(outputPath)\")",
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
    } else {
      let nsError = error as NSError
      errorCode = "system_error_\(nsError.code)"
      errorMessage = nsError.localizedDescription
    }

    return [
      "success": false,
      "command": "AVAssetReader+AVAssetWriter",
      "outputPath": request["outputPath"] ?? NSNull(),
      "engine": engineName,
      "outputFormat": outputFormat,
      "errorCode": errorCode,
      "errorMessage": errorMessage,
      "stdout": NSNull(),
      "stderr": NSNull(),
      "rawLog": NSNull(),
    ]
  }

  private static func normalizeFormat(_ format: String) -> String {
    let fmt = format.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if fmt == "m4a" || fmt == "m4b" || fmt == "aac" {
      return "m4a"
    }
    return fmt
  }

  private static func stringValue(_ dict: [String: Any], key: String) throws -> String {
    guard let val = dict[key] as? String else {
      throw ConversionError.missingRequiredArgument(key)
    }
    return val
  }

  private static func optionalStringValue(_ dict: [String: Any], key: String) -> String? {
    return dict[key] as? String
  }

  private static func intValue(_ dict: [String: Any], key: String) -> Int? {
    if let val = dict[key] as? Int {
      return val
    }
    if let val = dict[key] as? Double {
      return Int(val)
    }
    if let val = dict[key] as? String, let parsed = Int(val) {
      return parsed
    }
    return nil
  }

  private static func createParentDirectoryIfNeeded(for url: URL) throws {
    let parent = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
  }

  enum ConversionError: Error, LocalizedError {
    case missingRequiredArgument(String)
    case unsupportedOutputFormat(String)
    case noAudioTrack
    case readerStartFailed
    case writerStartFailed

    var code: String {
      switch self {
      case .missingRequiredArgument: return "missing_argument"
      case .unsupportedOutputFormat: return "unsupported_format"
      case .noAudioTrack: return "no_audio_track"
      case .readerStartFailed: return "reader_start_failed"
      case .writerStartFailed: return "writer_start_failed"
      }
    }

    var errorDescription: String? {
      switch self {
      case .missingRequiredArgument(let name):
        return "Missing required conversion argument: '\(name)'."
      case .unsupportedOutputFormat(let format):
        return "Output format '\(format)' is not supported by AVFoundation transcoder."
      case .noAudioTrack:
        return "No audio tracks found in the input asset."
      case .readerStartFailed:
        return "Failed to start AVAssetReader."
      case .writerStartFailed:
        return "Failed to start AVAssetWriter."
      }
    }
  }
}
