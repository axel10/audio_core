import AVFoundation
import Foundation

private func appleFFmpegTimestampMs() -> Double {
  CFAbsoluteTimeGetCurrent() * 1000.0
}

struct AppleFFmpegDecodedAudio {
  let sampleRate: Double
  let channels: Int
  let frameCount: AVAudioFramePosition
  let samples: [Float]

  var durationMs: Int {
    guard sampleRate > 0 else { return 0 }
    return max(0, Int(((Double(frameCount) / sampleRate) * 1000.0).rounded()))
  }

  var channelCount: Int {
    max(1, channels)
  }

  func samplesFromFrame(startFrame: AVAudioFramePosition, frameCount requestedFrameCount: Int) -> [Float] {
    guard requestedFrameCount > 0, channelCount > 0 else { return [] }
    let safeStart = max(0, min(startFrame, frameCount))
    let availableFrames = Int(max(0, frameCount - safeStart))
    let targetFrames = min(requestedFrameCount, availableFrames)
    guard targetFrames > 0 else { return [] }

    let startIndex = Int(safeStart) * channelCount
    let endIndex = startIndex + (targetFrames * channelCount)
    guard startIndex >= 0, endIndex <= samples.count else { return [] }
    return Array(samples[startIndex..<endIndex])
  }

  func interleavedSamples(
    startFrame: AVAudioFramePosition = 0,
    frameCount requestedFrameCount: Int? = nil,
    sampleStride: Int = 1
  ) -> [Float] {
    let stride = max(sampleStride, 1)
    let safeStart = max(0, min(startFrame, frameCount))
    let availableFrames = Int(max(0, frameCount - safeStart))
    let targetFrames = requestedFrameCount.map { min(max($0, 0), availableFrames) } ?? availableFrames
    guard targetFrames > 0 else { return [] }

    let startIndex = Int(safeStart) * channelCount
    let endIndex = startIndex + (targetFrames * channelCount)
    guard startIndex >= 0, endIndex <= samples.count else { return [] }

    var output: [Float] = []
    output.reserveCapacity((targetFrames / stride + 1) * channelCount)
    var frameIndex = 0
    var index = startIndex
    while index < endIndex {
      if frameIndex % stride == 0 {
        output.append(contentsOf: samples[index..<(index + channelCount)])
      }
      frameIndex += 1
      index += channelCount
    }
    return output
  }

  func monoSamples(
    startFrame: AVAudioFramePosition = 0,
    frameCount requestedFrameCount: Int? = nil
  ) -> [Double] {
    let safeStart = max(0, min(startFrame, frameCount))
    let availableFrames = Int(max(0, frameCount - safeStart))
    let targetFrames = requestedFrameCount.map { min(max($0, 0), availableFrames) } ?? availableFrames
    guard targetFrames > 0 else { return [] }

    let startIndex = Int(safeStart) * channelCount
    let endIndex = startIndex + (targetFrames * channelCount)
    guard startIndex >= 0, endIndex <= samples.count else { return [] }

    if channelCount == 1 {
      return samples[startIndex..<endIndex].map(Double.init)
    }

    var mono = Array(repeating: 0.0, count: targetFrames)
    for frame in 0..<targetFrames {
      let base = startIndex + (frame * channelCount)
      var sum = 0.0
      for channel in 0..<channelCount {
        sum += Double(samples[base + channel])
      }
      mono[frame] = sum / Double(channelCount)
    }
    return mono
  }

  func buildPCMBuffer(startFrame: AVAudioFramePosition, maxFrames: Int) -> AVAudioPCMBuffer? {
    guard maxFrames > 0, sampleRate > 0 else { return nil }
    let safeStart = max(0, min(startFrame, frameCount))
    let availableFrames = Int(max(0, frameCount - safeStart))
    let targetFrames = min(maxFrames, availableFrames)
    guard targetFrames > 0 else { return nil }

    let format = AVAudioFormat(
      standardFormatWithSampleRate: sampleRate,
      channels: AVAudioChannelCount(channelCount)
    )
    guard let format else { return nil }
    guard let buffer = AVAudioPCMBuffer(
      pcmFormat: format,
      frameCapacity: AVAudioFrameCount(targetFrames)
    ) else {
      return nil
    }

    buffer.frameLength = AVAudioFrameCount(targetFrames)
    guard let channelData = buffer.floatChannelData else { return nil }

    let startIndex = Int(safeStart) * channelCount
    for frame in 0..<targetFrames {
      let base = startIndex + (frame * channelCount)
      if channelCount == 1 {
        channelData[0][frame] = samples[base]
        continue
      }

      for channel in 0..<channelCount {
        channelData[channel][frame] = samples[base + channel]
      }
    }

    return buffer
  }

  func buildBufferQueue(
    startFrame: AVAudioFramePosition,
    chunkFrames: Int
  ) -> [AVAudioPCMBuffer] {
    guard chunkFrames > 0, frameCount > 0 else { return [] }

    var buffers: [AVAudioPCMBuffer] = []
    var nextFrame = max(0, min(startFrame, frameCount))
    while nextFrame < frameCount {
      guard let buffer = buildPCMBuffer(startFrame: nextFrame, maxFrames: chunkFrames) else {
        break
      }
      buffers.append(buffer)
      nextFrame += AVAudioFramePosition(buffer.frameLength)
    }
    return buffers
  }

  func resampled(to targetSampleRate: Double) throws -> AppleFFmpegDecodedAudio {
    let startMs = appleFFmpegTimestampMs()
    let safeTargetSampleRate = targetSampleRate.rounded()
    guard safeTargetSampleRate > 0 else {
      return self
    }

    // AVAudioPlayerNode expects scheduled PCM buffers to match the node's
    // output sample rate, so the FFmpeg path needs an explicit resample step.
    guard abs(safeTargetSampleRate - sampleRate.rounded()) >= 1 else {
      debugPrint(
        "[AppleFFmpegDecoder] resample skipped sampleRate=\(sampleRate) target=\(safeTargetSampleRate)"
      )
      return self
    }

    debugPrint(
      "[AppleFFmpegDecoder] resample start sampleRate=\(sampleRate) target=\(safeTargetSampleRate) " +
      "frames=\(frameCount) channels=\(channelCount)"
    )

    let sourceFormat = AVAudioFormat(
      standardFormatWithSampleRate: sampleRate,
      channels: AVAudioChannelCount(channelCount)
    )
    let targetFormat = AVAudioFormat(
      standardFormatWithSampleRate: safeTargetSampleRate,
      channels: AVAudioChannelCount(channelCount)
    )
    guard let sourceFormat, let targetFormat else {
      throw AppleFFmpegDecoderError.decodeFailed("failed to build resample formats")
    }

    guard let sourceBuffer = AVAudioPCMBuffer(
      pcmFormat: sourceFormat,
      frameCapacity: AVAudioFrameCount(frameCount)
    ) else {
      throw AppleFFmpegDecoderError.decodeFailed("failed to allocate source PCM buffer")
    }
    sourceBuffer.frameLength = AVAudioFrameCount(frameCount)
    guard let sourceChannelData = sourceBuffer.floatChannelData else {
      throw AppleFFmpegDecoderError.decodeFailed("failed to access source PCM channels")
    }

    let sourceFrameCount = Int(frameCount)
    for channel in 0..<channelCount {
      let channelSamples = sourceChannelData[channel]
      let baseIndex = channel
      for frame in 0..<sourceFrameCount {
        channelSamples[frame] = samples[(frame * channelCount) + baseIndex]
      }
    }

    guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
      throw AppleFFmpegDecoderError.decodeFailed("failed to create resampler")
    }

    let targetFrameCapacity = AVAudioFrameCount(
      max(
        1,
        Int((Double(frameCount) * safeTargetSampleRate / sampleRate).rounded(.up)) + 16
      )
    )
    guard let targetBuffer = AVAudioPCMBuffer(
      pcmFormat: targetFormat,
      frameCapacity: targetFrameCapacity
    ) else {
      throw AppleFFmpegDecoderError.decodeFailed("failed to allocate resampled PCM buffer")
    }

    var didProvideSourceBuffer = false
    var conversionError: NSError?
    let status = converter.convert(to: targetBuffer, error: &conversionError) { _, outStatus in
      if didProvideSourceBuffer {
        outStatus.pointee = .endOfStream
        return nil
      }

      didProvideSourceBuffer = true
      outStatus.pointee = .haveData
      return sourceBuffer
    }

    guard status != .error, conversionError == nil else {
      throw AppleFFmpegDecoderError.decodeFailed(
        conversionError?.localizedDescription ?? "failed to resample PCM"
      )
    }

    guard let targetChannelData = targetBuffer.floatChannelData else {
      throw AppleFFmpegDecoderError.decodeFailed("failed to access resampled PCM channels")
    }

    let resampledFrameCount = Int(targetBuffer.frameLength)
    var resampledSamples: [Float] = []
    resampledSamples.reserveCapacity(resampledFrameCount * channelCount)
    for frame in 0..<resampledFrameCount {
      for channel in 0..<channelCount {
        resampledSamples.append(targetChannelData[channel][frame])
      }
    }

    let result = AppleFFmpegDecodedAudio(
      sampleRate: safeTargetSampleRate,
      channels: channelCount,
      frameCount: AVAudioFramePosition(resampledFrameCount),
      samples: resampledSamples
    )
    debugPrint(
      "[AppleFFmpegDecoder] resample done durationMs=\(String(format: "%.1f", appleFFmpegTimestampMs() - startMs)) " +
      "outputFrames=\(resampledFrameCount)"
    )
    return result
  }
}

final class AppleFFmpegStreamAudio {
  private let path: String
  private(set) var sampleRate: Double = 0
  private(set) var channelCount: Int = 0
  private(set) var frameCount: AVAudioFramePosition = 0
  private(set) var startFrame: AVAudioFramePosition = 0
  private var decoder: UnsafeMutableRawPointer?
  var isOpen: Bool {
    decoder != nil
  }

  init(path: String, targetSampleRate: Double, startFrame: AVAudioFramePosition = 0) throws {
    self.path = path
    try open(targetSampleRate: targetSampleRate, startFrame: startFrame)
  }

  deinit {
    close()
  }

  func reopen(targetSampleRate: Double, startFrame: AVAudioFramePosition) throws {
    close()
    try open(targetSampleRate: targetSampleRate, startFrame: startFrame)
  }

  func ensureOpen(targetSampleRate: Double, startFrame: AVAudioFramePosition) throws {
    if decoder == nil || self.startFrame != startFrame || abs(sampleRate - targetSampleRate) >= 1 {
      try reopen(targetSampleRate: targetSampleRate, startFrame: startFrame)
    }
  }

  func close() {
    if let decoder {
      audio_core_ffmpeg_close_stream(decoder)
      self.decoder = nil
    }
  }

  func nextChunk(maxFrames: Int) throws -> AppleFFmpegDecodedAudio? {
    guard let decoder else { return nil }

    var decodedPCM = AudioCoreFFmpegDecodedPCM(
      samples: nil,
      sample_count: 0,
      channels: 0,
      sample_rate: 0,
      frame_count: 0
    )
    var isEOF = false
    var errorPointer: UnsafeMutablePointer<CChar>?
    let success = audio_core_ffmpeg_decode_stream_chunk(
      decoder,
      Int64(maxFrames),
      &decodedPCM,
      &isEOF,
      &errorPointer
    )

    defer {
      audio_core_ffmpeg_free_pcm(&decodedPCM)
      if let errorPointer {
        audio_core_ffmpeg_free_error(errorPointer)
      }
    }

    guard success else {
      let message = errorPointer.map { String(cString: $0) } ?? "ffmpeg stream decode failed"
      throw AppleFFmpegDecoderError.decodeFailed(message)
    }

    guard let samples = decodedPCM.samples else {
      if isEOF {
        return nil
      }
      return nil
    }

    let count = Int(decodedPCM.sample_count)
    let sampleArray = Array(UnsafeBufferPointer(start: samples, count: count))
    let chunk = AppleFFmpegDecodedAudio(
      sampleRate: decodedPCM.sample_rate,
      channels: Int(decodedPCM.channels),
      frameCount: AVAudioFramePosition(decodedPCM.frame_count),
      samples: sampleArray
    )
    if chunk.frameCount == 0 && isEOF {
      return nil
    }
    return chunk
  }

  private func open(targetSampleRate: Double, startFrame: AVAudioFramePosition) throws {
    var metadata = AudioCoreFFmpegDecodedPCM(
      samples: nil,
      sample_count: 0,
      channels: 0,
      sample_rate: 0,
      frame_count: 0
    )
    var errorPointer: UnsafeMutablePointer<CChar>?
    var handle: UnsafeMutableRawPointer?
    let success = path.withCString { cPath in
      audio_core_ffmpeg_open_stream(
        cPath,
        targetSampleRate,
        Int64(startFrame),
        &metadata,
        &handle,
        &errorPointer
      )
    }

    defer {
      audio_core_ffmpeg_free_pcm(&metadata)
      if let errorPointer {
        audio_core_ffmpeg_free_error(errorPointer)
      }
    }

    guard success, let handle else {
      let message = errorPointer.map { String(cString: $0) } ?? "ffmpeg stream open failed"
      throw AppleFFmpegDecoderError.decodeFailed(message)
    }

    decoder = handle
    sampleRate = metadata.sample_rate
    channelCount = Int(metadata.channels)
    frameCount = AVAudioFramePosition(metadata.frame_count)
    self.startFrame = startFrame
  }
}

enum AppleFFmpegDecoderError: LocalizedError {
  case decodeFailed(String)

  var errorDescription: String? {
    switch self {
    case .decodeFailed(let message):
      return message
    }
  }
}

enum AppleFFmpegDecoder {
  static func decode(path: String) throws -> AppleFFmpegDecodedAudio {
    let startMs = appleFFmpegTimestampMs()
    debugPrint("[AppleFFmpegDecoder] decode start path=\(path)")
    var decodedPCM = AudioCoreFFmpegDecodedPCM(
      samples: nil,
      sample_count: 0,
      channels: 0,
      sample_rate: 0,
      frame_count: 0
    )
    var errorPointer: UnsafeMutablePointer<CChar>?
    let success = path.withCString { cPath in
      audio_core_ffmpeg_decode_pcm(cPath, &decodedPCM, &errorPointer)
    }

    defer {
      audio_core_ffmpeg_free_pcm(&decodedPCM)
      if let errorPointer {
        audio_core_ffmpeg_free_error(errorPointer)
      }
    }

    guard success else {
      let message = errorPointer.map { String(cString: $0) } ?? "ffmpeg decode failed"
      debugPrint(
        "[AppleFFmpegDecoder] decode failed durationMs=\(String(format: "%.1f", appleFFmpegTimestampMs() - startMs)) " +
        "path=\(path) error=\(message)"
      )
      throw AppleFFmpegDecoderError.decodeFailed(message)
    }

    guard let samples = decodedPCM.samples else {
      throw AppleFFmpegDecoderError.decodeFailed("ffmpeg returned no PCM samples")
    }

    let count = Int(decodedPCM.sample_count)
    let sampleArray = Array(UnsafeBufferPointer(start: samples, count: count))
    let result = AppleFFmpegDecodedAudio(
      sampleRate: decodedPCM.sample_rate,
      channels: Int(decodedPCM.channels),
      frameCount: AVAudioFramePosition(decodedPCM.frame_count),
      samples: sampleArray
    )
    debugPrint(
      "[AppleFFmpegDecoder] decode done durationMs=\(String(format: "%.1f", appleFFmpegTimestampMs() - startMs)) " +
      "path=\(path) frames=\(decodedPCM.frame_count) channels=\(decodedPCM.channels) sampleRate=\(decodedPCM.sample_rate)"
    )
    return result
  }
}
