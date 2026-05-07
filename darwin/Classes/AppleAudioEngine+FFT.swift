import Accelerate
import AVFoundation
import Foundation

enum AppleFftAggregationMode: String {
  case peak
  case mean
  case rms
}

struct AppleFftGroupingConfig {
  var frequencyGroups: Int = 32
  var skipHighFrequencyGroups: Int = 0
  var aggregationMode: AppleFftAggregationMode = .peak
}

final class AppleFftCaptureBuffer {
  private let capacity: Int
  private var samples: [Float]
  private var writeIndex: Int = 0
  private var storedCount: Int = 0
  private let lock = NSLock()

  init(capacity: Int) {
    self.capacity = max(1, capacity)
    self.samples = Array(repeating: 0, count: self.capacity)
  }

  func clear() {
    lock.lock()
    writeIndex = 0
    storedCount = 0
    lock.unlock()
  }

  func append(buffer: AVAudioPCMBuffer) {
    let frameLength = Int(buffer.frameLength)
    guard frameLength > 0 else { return }
    guard let channelData = buffer.floatChannelData else { return }

    let channelCount = max(Int(buffer.format.channelCount), 1)

    lock.lock()
    defer { lock.unlock() }

    for frame in 0..<frameLength {
      var sum: Float = 0
      for channel in 0..<channelCount {
        sum += channelData[channel][frame]
      }
      samples[writeIndex] = sum / Float(channelCount)
      writeIndex += 1
      if writeIndex >= capacity {
        writeIndex = 0
      }
      if storedCount < capacity {
        storedCount += 1
      }
    }
  }

  func snapshot(lastFrames: Int) -> [Float] {
    guard lastFrames > 0 else { return [] }

    lock.lock()
    defer { lock.unlock() }

    let count = min(lastFrames, storedCount)
    guard count > 0 else { return [] }

    var output = Array(repeating: Float(0), count: count)
    let startIndex = writeIndex - count
    if startIndex >= 0 {
      output.replaceSubrange(0..<count, with: samples[startIndex..<(startIndex + count)])
      return output
    }

    let leadingCount = -startIndex
    let trailingCount = count - leadingCount
    output.replaceSubrange(0..<leadingCount, with: samples[(capacity - leadingCount)..<capacity])
    if trailingCount > 0 {
      output.replaceSubrange(leadingCount..<count, with: samples[0..<trailingCount])
    }
    return output
  }
}

extension AppleAudioEngine {
  func updateFftGroupingOptions(
    frequencyGroups: Int,
    skipHighFrequencyGroups: Int,
    aggregationMode: String
  ) {
    fftGroupingConfig = AppleFftGroupingConfig(
      frequencyGroups: max(1, min(frequencyGroups, fftBinCount)),
      skipHighFrequencyGroups: max(0, skipHighFrequencyGroups),
      aggregationMode: AppleFftAggregationMode(rawValue: aggregationMode) ?? .peak
    )
  }

  func getLatestFft() throws -> [Double] {
    // Keep the visualizer on the real playback tap path. Re-sampling from the
    // source file on every fetch adds avoidable work and makes the FFT feel
    // quantized/stale even while the tap is producing newer data.
    fftResultLock.lock()
    defer { fftResultLock.unlock() }
    if !pendingFftFrames.isEmpty {
      latestRawFft = pendingFftFrames.removeFirst()
    }
    return latestRawFft
  }

  func resetFftCaptureBuffer() {
    fftCaptureBuffer.clear()
    fftResultLock.lock()
    fftProcessingGeneration &+= 1
    latestRawFft = rawZeroFrame()
    latestRawTapMagnitudes = Array(repeating: 0.0, count: fftBinCount)
    fftAnalysisRemainder.removeAll(keepingCapacity: true)
    pendingFftFrames.removeAll(keepingCapacity: true)
    fftResultLock.unlock()
    fftTapCount = 0
    fftLastTapAtMs = nil
  }

  func installFftCaptureTapIfNeeded() {
    guard !isFftTapInstalled else { return }
    equalizerNode.installTap(
      onBus: 0,
      bufferSize: AVAudioFrameCount(fftSize / 2),
      format: nil
    ) { [weak self] buffer, _ in
      self?.handleFftTapBuffer(buffer)
    }
    isFftTapInstalled = true
  }

  func handleFftTapBuffer(_ buffer: AVAudioPCMBuffer) {
    fftCaptureBuffer.append(buffer: buffer)
    let monoSamples = monoSamples(from: buffer)
    guard !monoSamples.isEmpty else { return }
    let frameLength = Int(buffer.frameLength)
    let generation = currentFftProcessingGeneration()
    fftProcessingQueue.async { [weak self] in
      self?.enqueueTapFftFrames(
        monoSamples,
        frameLength: frameLength,
        generation: generation
      )
    }
  }

  func monoSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
    let frameLength = Int(buffer.frameLength)
    guard frameLength > 0 else { return [] }
    guard let channelData = buffer.floatChannelData else { return [] }

    let channelCount = max(Int(buffer.format.channelCount), 1)
    if channelCount == 1 {
      return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
    }

    var mono = Array(repeating: Float(0), count: frameLength)
    for frame in 0..<frameLength {
      var sum: Float = 0
      for channel in 0..<channelCount {
        sum += channelData[channel][frame]
      }
      mono[frame] = sum / Float(channelCount)
    }
    return mono
  }

  func enqueueTapFftFrames(
    _ monoSamples: [Float],
    frameLength: Int? = nil,
    generation: UInt64
  ) {
    guard isCurrentFftProcessingGeneration(generation) else { return }
    var windows: [[Float]] = []
    var previousLatest = rawZeroFrame()
    var previousTapMagnitudes = Array(repeating: 0.0, count: fftBinCount)

    fftResultLock.lock()
    guard fftProcessingGeneration == generation else {
      fftResultLock.unlock()
      return
    }
    previousLatest = latestRawFft
    previousTapMagnitudes = latestRawTapMagnitudes
    fftAnalysisRemainder.append(contentsOf: monoSamples)
    while fftAnalysisRemainder.count >= fftSize {
      windows.append(Array(fftAnalysisRemainder.prefix(fftSize)))
      fftAnalysisRemainder.removeFirst(fftHopSize)
    }
    fftResultLock.unlock()

    guard !windows.isEmpty else { return }

    var queuedFrames: [[Double]] = []
    queuedFrames.reserveCapacity(windows.count)
    for window in windows {
      queuedFrames.append(computeMagnitudes(from: window))
    }

    guard let latestMagnitudes = queuedFrames.last else { return }
    guard isCurrentFftProcessingGeneration(generation) else { return }

    let tapNowMs = currentTimestampMs()
    fftTapCount &+= 1
    let tapDeltaMs = fftLastTapAtMs.map { tapNowMs - $0 }
    fftLastTapAtMs = tapNowMs

    let rawDelta = meanAbsoluteDelta(latestMagnitudes, comparedTo: previousLatest)
    let magnitudeDelta = meanAbsoluteDelta(latestMagnitudes, comparedTo: previousTapMagnitudes)

    fftResultLock.lock()
    guard fftProcessingGeneration == generation else {
      fftResultLock.unlock()
      return
    }
    pendingFftFrames.append(contentsOf: queuedFrames)
    if pendingFftFrames.count > fftFrameQueueCapacity {
      pendingFftFrames.removeFirst(pendingFftFrames.count - fftFrameQueueCapacity)
    }
    latestRawFft = latestMagnitudes
    latestRawTapMagnitudes = latestMagnitudes
    let queueDepth = pendingFftFrames.count
    fftResultLock.unlock()

    if fftTapCount <= 5 || fftTapCount % 30 == 0 {
      debugPrint(
        "[AppleAudioEngine] fft tap count=\(fftTapCount) " +
        "frameLength=\(frameLength.map(String.init) ?? "nil") " +
        "producedFrames=\(queuedFrames.count) " +
        "queueDepth=\(queueDepth) " +
        "deltaMs=\(tapDeltaMs.map { String(format: "%.1f", $0) } ?? "nil") " +
        "rawDelta=\(String(format: "%.6f", rawDelta)) " +
        "magnitudeDelta=\(String(format: "%.6f", magnitudeDelta)) " +
        "first=\(latestMagnitudes.first.map { String(format: "%.6f", $0) } ?? "nil")"
      )
    }
  }

  func currentFftProcessingGeneration() -> UInt64 {
    fftResultLock.lock()
    let generation = fftProcessingGeneration
    fftResultLock.unlock()
    return generation
  }

  func isCurrentFftProcessingGeneration(_ generation: UInt64) -> Bool {
    fftResultLock.lock()
    let isCurrent = fftProcessingGeneration == generation
    fftResultLock.unlock()
    return isCurrent
  }

  func meanAbsoluteDelta(_ lhs: [Double], comparedTo rhs: [Double]) -> Double {
    let count = min(lhs.count, rhs.count)
    guard count > 0 else { return 0.0 }
    var total = 0.0
    for index in 0..<count {
      total += abs(lhs[index] - rhs[index])
    }
    return total / Double(count)
  }

  func rawZeroFrame() -> [Double] {
    Array(repeating: 0.0, count: fftBinCount)
  }

  func computeMagnitudes(from samples: [Float]) -> [Double] {
    let count = min(samples.count, fftSize)
    guard count > 0 else {
      return Array(repeating: 0.0, count: fftBinCount)
    }

    var windowed = Array(repeating: Float(0), count: fftSize)
    let denominator = max(Float(count - 1), 1.0)
    var windowSum = 0.0
    for index in 0..<count {
      let phase = (2.0 * Double.pi * Double(index)) / Double(denominator)
      let weight = Float(0.5 - 0.5 * cos(phase))
      windowed[index] = samples[index] * weight
      windowSum += Double(weight)
    }
    let safeWindowSum = max(windowSum, 1e-9)

    guard let fftSetup else {
      return Array(repeating: 0.0, count: fftBinCount)
    }

    var real = Array(repeating: Float(0), count: fftBinCount)
    var imag = Array(repeating: Float(0), count: fftBinCount)
    for index in 0..<fftBinCount {
      real[index] = windowed[index * 2]
      imag[index] = windowed[(index * 2) + 1]
    }

    return real.withUnsafeMutableBufferPointer { realBuffer in
      imag.withUnsafeMutableBufferPointer { imagBuffer in
        var splitComplex = DSPSplitComplex(
          realp: realBuffer.baseAddress!,
          imagp: imagBuffer.baseAddress!
        )
        vDSP_fft_zrip(fftSetup, &splitComplex, 1, fftLog2Size, FFTDirection(FFT_FORWARD))

        var magnitudes = Array(repeating: 0.0, count: fftBinCount)
        magnitudes[0] = Double(abs(splitComplex.realp[0])) / safeWindowSum
        if fftBinCount > 1 {
          for bin in 1..<fftBinCount {
            let realValue = Double(splitComplex.realp[bin])
            let imagValue = Double(splitComplex.imagp[bin])
            magnitudes[bin] = (sqrt((realValue * realValue) + (imagValue * imagValue)) * 2.0) / safeWindowSum
          }
        }
        return magnitudes
      }
    }
  }
}
