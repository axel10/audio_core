import Accelerate
import AVFoundation
import Foundation
import os

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

final class AppleFftWorkspace {
  let fftSize: Int
  let fftBinCount: Int
  
  var window: [Float]
  var windowed: [Float]
  var real: [Float]
  var imag: [Float]
  var windowSum: Double = 0
  
  init(fftSize: Int) {
    self.fftSize = fftSize
    self.fftBinCount = fftSize / 2
    
    self.window = Array(repeating: 0, count: fftSize)
    self.windowed = Array(repeating: 0, count: fftSize)
    self.real = Array(repeating: 0, count: fftBinCount)
    self.imag = Array(repeating: 0, count: fftBinCount)
    
    // Create Hann window
    vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    
    // Calculate the actual sum of the window for accurate normalization later
    var sum: Float = 0
    vDSP_sve(window, 1, &sum, vDSP_Length(fftSize))
    self.windowSum = max(Double(sum), 1e-9)
  }
}

final class AppleFftRingBuffer {
  private let capacity: Int
  private var samples: UnsafeMutablePointer<Float>
  private var writeIndex: Int = 0
  private var available: Int = 0
  private var lock = os_unfair_lock_s()

  init(capacity: Int) {
    self.capacity = max(1, capacity)
    self.samples = .allocate(capacity: self.capacity)
    self.samples.initialize(repeating: 0, count: self.capacity)
  }
  
  deinit {
    self.samples.deallocate()
  }

  func clear() {
    os_unfair_lock_lock(&lock)
    writeIndex = 0
    available = 0
    os_unfair_lock_unlock(&lock)
  }

  func pushMono(from buffer: AVAudioPCMBuffer) {
    let frameLength = Int(buffer.frameLength)
    guard frameLength > 0, let channelData = buffer.floatChannelData else { return }
    let channelCount = Int(buffer.format.channelCount)

    os_unfair_lock_lock(&lock)
    defer { os_unfair_lock_unlock(&lock) }

    for frame in 0..<frameLength {
      var sum: Float = 0
      for channel in 0..<channelCount {
        sum += channelData[channel][frame]
      }
      samples[writeIndex] = sum / Float(channelCount)
      writeIndex += 1
      if writeIndex >= capacity { writeIndex = 0 }
      if available < capacity { available += 1 }
    }
  }

  func pullAll() -> [Float] {
    os_unfair_lock_lock(&lock)
    defer { os_unfair_lock_unlock(&lock) }

    guard available > 0 else { return [] }

    var result = Array(repeating: Float(0), count: available)
    var readIndex = writeIndex - available
    if readIndex < 0 { readIndex += capacity }

    for i in 0..<available {
      result[i] = samples[readIndex]
      readIndex += 1
      if readIndex >= capacity { readIndex = 0 }
    }
    available = 0
    return result
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
    guard isPlaying else { return }
    
    // 1. Thread-safe push without allocating memory on Real-time audio thread
    fftCaptureBuffer.pushMono(from: buffer)
    
    let generation = currentFftProcessingGeneration()
    let frameLength = Int(buffer.frameLength)
    
    // 2. Dispatch FFT processing to background queue.
    // By passing only generation and frameLength, we avoid capturing arrays in the dispatch closure
    fftProcessingQueue.async { [weak self] in
      self?.processFftRingBuffer(frameLength: frameLength, generation: generation)
    }
  }

  func processFftRingBuffer(frameLength: Int, generation: UInt64) {
    guard isCurrentFftProcessingGeneration(generation) else { return }
    
    let monoSamples = fftCaptureBuffer.pullAll()
    guard !monoSamples.isEmpty else { return }
    
    enqueueTapFftFrames(monoSamples, frameLength: frameLength, generation: generation)
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
    guard count > 0, let fftSetup = fftSetup else {
      return rawZeroFrame()
    }

    // 1. Apply precomputed Hann Window using vDSP
    if count < fftSize {
        fftWorkspace.windowed.withUnsafeMutableBufferPointer { ptr in
            ptr.initialize(repeating: 0)
        }
    }
    vDSP_vmul(samples, 1, fftWorkspace.window, 1, &fftWorkspace.windowed, 1, vDSP_Length(count))
    
    var magnitudes = Array(repeating: 0.0, count: fftBinCount)

    // 2. Extract real and imaginary parts using existing memory buffers
    for index in 0..<fftBinCount {
        fftWorkspace.real[index] = fftWorkspace.windowed[index * 2]
        fftWorkspace.imag[index] = fftWorkspace.windowed[(index * 2) + 1]
    }
    
    fftWorkspace.real.withUnsafeMutableBufferPointer { realBuffer in
        fftWorkspace.imag.withUnsafeMutableBufferPointer { imagBuffer in
            var splitComplex = DSPSplitComplex(
                realp: realBuffer.baseAddress!,
                imagp: imagBuffer.baseAddress!
            )
            
            // 3. Perform Forward FFT
            vDSP_fft_zrip(fftSetup, &splitComplex, 1, fftLog2Size, FFTDirection(FFT_FORWARD))
            
            // 4. Compute Magnitudes
            let safeWindowSum = fftWorkspace.windowSum
            magnitudes[0] = Double(abs(splitComplex.realp[0])) / safeWindowSum
            if fftBinCount > 1 {
                for bin in 1..<fftBinCount {
                    let realValue = Double(splitComplex.realp[bin])
                    let imagValue = Double(splitComplex.imagp[bin])
                    magnitudes[bin] = (sqrt((realValue * realValue) + (imagValue * imagValue)) * 2.0) / safeWindowSum
                }
            }
        }
    }
    return magnitudes
  }
}
