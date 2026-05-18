import AVFoundation
import Foundation

extension AppleAudioEngine {
  func getWaveform(path: String, expectedChunks: Int) throws -> [Double] {
    guard expectedChunks > 0 else { return [] }
    return try withDecodedAudioSource(path: path) { source in
      return processWaveform(
        samples: try source.monoSamples(),
        expectedChunks: expectedChunks
      )
    }
  }

  func getAudioPcm(path: String, sampleStride: Int) throws -> [Float] {
    return try withDecodedAudioSource(path: path) { source in
      return try source.interleavedSamples(sampleStride: sampleStride)
    }
  }

  func getAudioPcmChannelCount(path: String) throws -> Int {
    try withDecodedAudioSource(path: path) { source in
      return source.channelCount
    }
  }

  func getFingerprintPcm(path: String, maxDurationMs: Int) throws -> [String: Any] {
    try withDecodedAudioSource(path: path) { source in
      return [
        "samples": try source.interleavedSamples(sampleStride: 1, maxDurationMs: maxDurationMs),
        "sampleRate": Int(source.sampleRate.rounded()),
        "channels": source.channelCount,
      ]
    }
  }

  func withDecodedAudioSource<T>(
    path: String,
    _ work: (AppleAudioSampleSource) throws -> T
  ) throws -> T {
    try fileAccess.withTemporaryAccess(for: path) { url in
      let source = try decodeAsset(for: url)
      return try work(source)
    }
  }

  static func readInterleavedPCM(
    file: AVAudioFile,
    sampleStride: Int,
    maxDurationMs: Int = 0
  ) throws -> [Float] {
    let format = file.processingFormat
    let channels = Int(format.channelCount)
    let stride = max(sampleStride, 1)
    let bufferCapacity: AVAudioFrameCount = 4096
    let requestedMaxFrames = AVAudioFramePosition(
      (format.sampleRate * Double(maxDurationMs) / 1000.0).rounded(.down)
    )
    let maxFrameLimit = maxDurationMs > 0 ? requestedMaxFrames : file.length
    let endFrame = min(file.length, maxFrameLimit)
    guard file.framePosition < endFrame else {
      return []
    }
    guard let buffer = AVAudioPCMBuffer(
      pcmFormat: format,
      frameCapacity: bufferCapacity
    ) else {
      return []
    }

    var samples: [Float] = []
    var frameIndex = 0
    while file.framePosition < endFrame {
      let framesRemaining = AVAudioFrameCount(endFrame - file.framePosition)
      let framesToRead = min(bufferCapacity, framesRemaining)
      try file.read(into: buffer, frameCount: framesToRead)
      let frameLength = Int(buffer.frameLength)
      guard let channelData = buffer.floatChannelData else {
        continue
      }

      for frame in 0..<frameLength {
        if sampleStride > 0, frameIndex % stride != 0 {
          frameIndex += 1
          continue
        }
        for channel in 0..<channels {
          samples.append(channelData[channel][frame])
        }
        frameIndex += 1
      }
    }
    return samples
  }

  static func readFFmpegStreamInterleavedPCM(
    stream: AppleFFmpegStreamAudio,
    sampleStride: Int,
    maxFrames: Int
  ) throws -> [Float] {
    guard maxFrames > 0 else { return [] }
    guard let chunk = try stream.makeTemporaryChunk(startFrame: 0, maxFrames: maxFrames) else {
      return []
    }
    return chunk.interleavedSamples(
      startFrame: 0,
      frameCount: Int(chunk.frameCount),
      sampleStride: sampleStride
    )
  }

  static func readInterleavedPCM(
    url: URL,
    sampleStride: Int,
    maxDurationMs: Int = 0
  ) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    return try Self.readInterleavedPCM(file: file, sampleStride: sampleStride, maxDurationMs: maxDurationMs)
  }

  func mixToMonoSamples(_ pcm: [Float], channels: Int) -> [Double] {
    let safeChannels = max(channels, 1)
    if safeChannels == 1 {
      return pcm.map(Double.init)
    }

    let frameCount = pcm.count / safeChannels
    guard frameCount > 0 else { return [] }

    var mono = Array(repeating: 0.0, count: frameCount)
    for frame in 0..<frameCount {
      let base = frame * safeChannels
      var sum = 0.0
      for channel in 0..<safeChannels {
        sum += Double(pcm[base + channel])
      }
      mono[frame] = sum / Double(safeChannels)
    }
    return mono
  }

  func processWaveform(samples: [Double], expectedChunks: Int) -> [Double] {
    guard expectedChunks > 0 else { return [] }
    guard !samples.isEmpty else {
      return Array(repeating: 0.0, count: expectedChunks)
    }

    let windowCount = max(
      expectedChunks,
      min(samples.count, expectedChunks * waveformRmsWindowsPerChunk)
    )
    var envelope = Array(repeating: 0.0, count: windowCount)

    for window in 0..<windowCount {
      let start = (window * samples.count) / windowCount
      let end = ((window + 1) * samples.count) / windowCount
      guard end > start else { continue }
      envelope[window] = computeRms(samples: samples, start: start, end: end)
    }

    var output = Array(repeating: 0.0, count: expectedChunks)
    for chunk in 0..<expectedChunks {
      let start = (chunk * windowCount) / expectedChunks
      let end = ((chunk + 1) * windowCount) / expectedChunks
      var maxValue = 0.0
      if end > start {
        for index in start..<end {
          if envelope[index] > maxValue {
            maxValue = envelope[index]
          }
        }
      }
      output[chunk] = roundWaveformPrecision(max(0.0, min(maxValue, 1.0)))
    }
    return output
  }

  func computeRms(samples: [Double], start: Int, end: Int) -> Double {
    guard end > start else { return 0.0 }
    var sum = 0.0
    for index in start..<end {
      let sample = samples[index]
      sum += sample * sample
    }
    return sqrt(sum / Double(end - start))
  }

  func roundWaveformPrecision(_ value: Double) -> Double {
    (value * waveformPrecisionScale).rounded() / waveformPrecisionScale
  }

  static func readMonoWindow(
    file: AVAudioFile,
    startFrame: AVAudioFramePosition,
    frameCount: Int
  ) throws -> [Float] {
    let format = file.processingFormat
    let channels = Int(format.channelCount)
    let safeStart = max(0, min(startFrame, file.length))
    file.framePosition = safeStart

    let availableFrames = Int(max(0, file.length - safeStart))
    let targetFrames = min(frameCount, availableFrames)
    guard targetFrames > 0 else {
      return Array(repeating: 0.0, count: frameCount)
    }

    guard let buffer = AVAudioPCMBuffer(
      pcmFormat: format,
      frameCapacity: AVAudioFrameCount(targetFrames)
    ) else {
      return Array(repeating: 0.0, count: frameCount)
    }

    try file.read(into: buffer, frameCount: AVAudioFrameCount(targetFrames))
    let frameLength = Int(buffer.frameLength)
    guard let channelData = buffer.floatChannelData else {
      return Array(repeating: 0.0, count: frameCount)
    }

    var mono = Array(repeating: Float(0.0), count: frameCount)
    for frame in 0..<frameLength {
      var sum: Float = 0.0
      for channel in 0..<channels {
        sum += channelData[channel][frame]
      }
      mono[frame] = sum / Float(max(channels, 1))
    }
    return mono
  }

  static func readFFmpegStreamMonoWindow(
    stream: AppleFFmpegStreamAudio,
    startFrame: AVAudioFramePosition,
    frameCount: Int
  ) throws -> [Double] {
    guard frameCount > 0 else { return [] }
    guard let chunk = try stream.makeTemporaryChunk(startFrame: startFrame, maxFrames: frameCount) else {
      return Array(repeating: 0.0, count: frameCount)
    }
    return chunk.monoSamples(startFrame: 0, frameCount: frameCount)
  }

  static func readMonoWindow(
    url: URL,
    startFrame: AVAudioFramePosition,
    frameCount: Int
  ) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    return try Self.readMonoWindow(file: file, startFrame: startFrame, frameCount: frameCount)
  }
}
