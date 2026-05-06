import AVFoundation
import Foundation

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
      throw AppleFFmpegDecoderError.decodeFailed(message)
    }

    guard let samples = decodedPCM.samples else {
      throw AppleFFmpegDecoderError.decodeFailed("ffmpeg returned no PCM samples")
    }

    let count = Int(decodedPCM.sample_count)
    let sampleArray = Array(UnsafeBufferPointer(start: samples, count: count))
    return AppleFFmpegDecodedAudio(
      sampleRate: decodedPCM.sample_rate,
      channels: Int(decodedPCM.channels),
      frameCount: AVAudioFramePosition(decodedPCM.frame_count),
      samples: sampleArray
    )
  }
}
