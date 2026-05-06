import Accelerate
import AVFoundation
import Foundation

private enum AppleFftAggregationMode: String {
  case peak
  case mean
  case rms
}

private struct AppleFftGroupingConfig {
  var frequencyGroups: Int = 32
  var skipHighFrequencyGroups: Int = 0
  var aggregationMode: AppleFftAggregationMode = .peak
}

private enum AppleAudioLoadBackend {
  case avFoundation
  case ffmpeg
}

private enum AppleAudioSampleSource {
  case avFoundation(AVAudioFile)
  case ffmpeg(AppleFFmpegDecodedAudio)
  case ffmpegStream(AppleFFmpegStreamAudio)

  var sampleRate: Double {
    switch self {
    case .avFoundation(let file):
      return file.processingFormat.sampleRate
    case .ffmpeg(let decoded):
      return decoded.sampleRate
    case .ffmpegStream(let stream):
      return stream.sampleRate
    }
  }

  var channelCount: Int {
    switch self {
    case .avFoundation(let file):
      return Int(file.processingFormat.channelCount)
    case .ffmpeg(let decoded):
      return decoded.channelCount
    case .ffmpegStream(let stream):
      return stream.channelCount
    }
  }

  var frameCount: AVAudioFramePosition {
    switch self {
    case .avFoundation(let file):
      return file.length
    case .ffmpeg(let decoded):
      return decoded.frameCount
    case .ffmpegStream(let stream):
      return stream.frameCount
    }
  }

  func interleavedSamples(
    sampleStride: Int = 1,
    maxDurationMs: Int = 0
  ) throws -> [Float] {
    switch self {
    case .avFoundation(let file):
      return try AppleAudioEngine.readInterleavedPCM(
        file: file,
        sampleStride: sampleStride,
        maxDurationMs: maxDurationMs
      )
    case .ffmpeg(let decoded):
      let durationFrames = maxDurationMs > 0
        ? AVAudioFramePosition((decoded.sampleRate * Double(maxDurationMs) / 1000.0).rounded(.down))
        : decoded.frameCount
      return decoded.interleavedSamples(
        startFrame: 0,
        frameCount: Int(durationFrames),
        sampleStride: sampleStride
      )
    case .ffmpegStream(let stream):
      let durationFrames = maxDurationMs > 0
        ? AVAudioFramePosition((stream.sampleRate * Double(maxDurationMs) / 1000.0).rounded(.down))
        : stream.frameCount
      return try AppleAudioEngine.readFFmpegStreamInterleavedPCM(
        stream: stream,
        sampleStride: sampleStride,
        maxFrames: Int(durationFrames)
      )
    }
  }

  func monoSamples(
    startFrame: AVAudioFramePosition = 0,
    frameCount: Int? = nil
  ) throws -> [Double] {
    switch self {
    case .avFoundation(let file):
      return try AppleAudioEngine.readMonoWindow(
        file: file,
        startFrame: startFrame,
        frameCount: frameCount ?? Int(file.length)
      ).map(Double.init)
    case .ffmpeg(let decoded):
      return decoded.monoSamples(startFrame: startFrame, frameCount: frameCount)
    case .ffmpegStream(let stream):
      return try AppleAudioEngine.readFFmpegStreamMonoWindow(
        stream: stream,
        startFrame: startFrame,
        frameCount: frameCount ?? Int(stream.frameCount)
      )
    }
  }
}

private final class AppleFftCaptureBuffer {
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

final class AppleAudioEngine {
  private struct PendingEdit {
    let path: String
    let positionMs: Int
    let wasPlaying: Bool
    let volume: Double
  }

  private let fftSize = 1024
  private let fftBinCount = 512
  private let fftLog2Size: vDSP_Length = 9
  private let ffmpegScheduleChunkFrames = 4096
  private let ffmpegPlaybackLookaheadBuffers = 3
  private let ffmpegPlaybackQueue = DispatchQueue(label: "audio_core.ffmpeg.playback", qos: .userInitiated)
  private let waveformRmsWindowsPerChunk = 8
  private let waveformPrecisionScale = 100.0
  private let avFoundationPreferredExtensions: Set<String> = [
    "aac", "aif", "aiff", "caf", "m4a", "m4p", "mp3", "mp4", "m4v", "mov", "wav","flac"
  ]
  private let fileAccess: SecurityScopedFileAccessCoordinator
  private let engine = AVAudioEngine()
  private let deckMixerNode = AVAudioMixerNode()
  private let equalizerNode = AVAudioUnitEQ(numberOfBands: AppleEqualizerDefaults.maxBands + 1)
  private let currentDeck = PlaybackDeck()
  private let incomingDeck = PlaybackDeck()
  private var latestVolume: Double = 1.0
  private var latestEqualizerConfig = AppleEqualizerCodec.defaultConfig()
  private var pendingEdit: PendingEdit?
  private var fadeTimer: Timer?
  private var fadeGeneration: UInt64 = 0
  private var preparedAccessPaths = Set<String>()
  private var isEngineConfigured = false
  private var fftGroupingConfig = AppleFftGroupingConfig()
  private let fftSetup: FFTSetup?
  private let fftCaptureBuffer = AppleFftCaptureBuffer(capacity: 16_384)
  private let fftResultLock = NSLock()
  private var latestFftFrame: [Double]
  private var latestRawTapMagnitudes: [Double]
  private var fftTapCount: Int = 0
  private var fftLastTapAtMs: Double?
  private var isFftTapInstalled = false

  var onPlayerStateChanged: ((String?, String?) -> Void)?

  private func currentTimestampMs() -> Double {
    CFAbsoluteTimeGetCurrent() * 1000.0
  }

  init(fileAccess: SecurityScopedFileAccessCoordinator) {
    self.fileAccess = fileAccess
    self.fftSetup = vDSP_create_fftsetup(fftLog2Size, FFTRadix(kFFTRadix2))
    self.latestFftFrame = Array(repeating: 0.0, count: fftBinCount)
    self.latestRawTapMagnitudes = Array(repeating: 0.0, count: fftBinCount)
    configureEngineIfNeeded()
    applyEqualizerConfig(latestEqualizerConfig)
  }

  deinit {
    if let fftSetup {
      vDSP_destroy_fftsetup(fftSetup)
    }
    equalizerNode.removeTap(onBus: 0)
  }

  func ensureReady() {
    // The native engine is lazy; no-op here keeps the channel contract simple.
  }

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
    refreshLatestFftFrame()
  }

  var isPlaying: Bool {
    publicDeck()?.isPlaying ?? false
  }

  func load(path: String) throws {
    let startMs = currentTimestampMs()
    debugPrint(
      "[AppleAudioEngine] load start path=\(path) public=\(publicURL()?.path ?? "nil")"
    )
    stopPlayback(releasingFile: true, preservePosition: false)
    releaseCurrentAccessIfNeeded()

    let url = try fileAccess.acquireAccess(for: path)
    let acquireDoneMs = currentTimestampMs()
    debugPrint(
      "[AppleAudioEngine] load access ready path=\(path) elapsedMs=\(String(format: "%.1f", acquireDoneMs - startMs))"
    )
    try loadAsset(into: currentDeck, from: url)
    preparedAccessPaths.remove(url.path)
    debugPrint(
      "[AppleAudioEngine] load done path=\(path) sampleRate=\(currentDeck.sampleRate) " +
      "length=\(currentDeck.frameCount) elapsedMs=\(String(format: "%.1f", currentTimestampMs() - startMs)) " +
      "public=\(publicURL()?.path ?? "nil")"
    )
  }

  func crossfade(path: String, durationMs: Int, positionMs: Int? = nil) throws {
    debugPrint(
      "[AppleAudioEngine] crossfade request path=\(path) durationMs=\(durationMs) " +
      "positionMs=\(positionMs.map(String.init) ?? "nil") current=\(publicURL()?.path ?? "nil") " +
      "isPlaying=\(publicDeck()?.isPlaying ?? false)"
    )
    let duration = max(0, durationMs)
    guard currentDeck.isLoaded, currentDeck.isPlaying, duration > 0 else {
      try load(path: path)
      if let positionMs, positionMs > 0 {
        try seek(positionMs: positionMs)
      }
      try play(fadeDurationMs: duration, targetVolume: latestVolume)
      return
    }

    try startCrossfade(path: path, durationMs: duration, positionMs: positionMs)
  }

  func play(fadeDurationMs: Int, targetVolume: Double?) throws {
    debugPrint(
      "[AppleAudioEngine] play request fadeDurationMs=\(fadeDurationMs) " +
      "targetVolume=\(targetVolume.map { String(format: "%.3f", $0) } ?? "nil") " +
      "public=\(publicURL()?.path ?? "nil")"
    )
    guard let activeDeck = publicDeck() else {
      throw NSError(
        domain: "AudioCore",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "audio is not loaded"]
      )
    }

    let target = (targetVolume ?? latestVolume).clamped(to: 0.0...1.0)
    latestVolume = target
    try startPlaybackIfNeeded(on: activeDeck, from: activeDeck.currentPlaybackFramePosition(), volume: target)

    if fadeDurationMs > 0 {
      activeDeck.playerNode.volume = 0.0
      fadeVolume(
        from: 0.0,
        to: target,
        durationMs: fadeDurationMs,
        update: { nextVolume in
          activeDeck.playerNode.volume = Float(nextVolume)
        },
        completion: {
          activeDeck.playerNode.volume = Float(target)
        }
      )
    } else {
      activeDeck.playerNode.volume = Float(target)
    }
  }

  func pause(fadeDurationMs: Int) throws {
    debugPrint(
      "[AppleAudioEngine] pause request fadeDurationMs=\(fadeDurationMs) " +
      "public=\(publicURL()?.path ?? "nil") isPlaying=\(publicDeck()?.isPlaying ?? false)"
    )
    guard let activeDeck = publicDeck(), activeDeck.isPlaying else { return }

    if fadeDurationMs > 0 {
      let originalVolume = Double(activeDeck.playerNode.volume)
      fadeVolume(
        from: originalVolume,
        to: 0.0,
        durationMs: fadeDurationMs,
        update: { nextVolume in
          activeDeck.playerNode.volume = Float(nextVolume)
        },
        completion: { [weak self] in
          guard let self = self else { return }
          self.pausePlayback(preservePosition: true)
          self.restoreDeckVolumes()
        }
      )
    } else {
      pausePlayback(preservePosition: true)
      restoreDeckVolumes()
    }
  }

  func seek(positionMs: Int) throws {
    debugPrint(
      "[AppleAudioEngine] seek request positionMs=\(positionMs) " +
      "public=\(publicURL()?.path ?? "nil")"
    )
    guard let currentDeck = publicDeck() else {
      throw NSError(
        domain: "AudioCore",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "audio is not loaded"]
      )
    }

    let targetFrame = framePosition(forMilliseconds: positionMs, sampleRate: currentDeck.sampleRate)
    let clampedFrame = max(0, min(targetFrame, currentDeck.frameCount))
    let wasPlaying = currentDeck.isPlaying
    currentDeck.playbackFramePosition = clampedFrame

    if wasPlaying {
      stopPlayback(releasingFile: false, preservePosition: true)
      try startPlaybackIfNeeded(on: currentDeck, from: clampedFrame, volume: latestVolume)
    }
    debugPrint(
      "[AppleAudioEngine] seek applied positionMs=\(positionMs) frame=\(clampedFrame) " +
      "wasPlaying=\(wasPlaying)"
    )
  }

  func setVolume(_ volume: Double) throws {
    let clamped = volume.clamped(to: 0.0...1.0)
    latestVolume = clamped
    if currentDeck.isLoaded {
      currentDeck.playerNode.volume = Float(clamped * currentDeck.gain)
    }
    if incomingDeck.isLoaded {
      incomingDeck.playerNode.volume = Float(clamped * incomingDeck.gain)
    }
  }

  func getDurationMs() -> Int {
    let frameCount = publicFrameCount()
    guard frameCount > 0 else { return 0 }
    return max(0, frameCountToMilliseconds(frameCount, sampleRate: publicSampleRate()))
  }

  func getCurrentPositionMs() -> Int {
    guard let deck = publicDeck() else { return 0 }
    return max(0, framePositionToMilliseconds(deck.currentPlaybackFramePosition(), sampleRate: deck.sampleRate))
  }

  func getLatestFft() throws -> [Double] {
    if let sampledFrame = try sampleFftFrameFromPlaybackPosition() {
      return sampledFrame
    }
    fftResultLock.lock()
    defer { fftResultLock.unlock() }
    return latestFftFrame
  }

  func getWaveform(path: String, expectedChunks: Int) throws -> [Double] {
    guard expectedChunks > 0 else { return [] }
    return try fileAccess.withTemporaryAccess(for: path) { url in
      let source = try decodeAsset(for: url)
      return processWaveform(
        samples: try source.monoSamples(),
        expectedChunks: expectedChunks
      )
    }
  }

  func getAudioPcm(path: String, sampleStride: Int) throws -> [Float] {
    return try fileAccess.withTemporaryAccess(for: path) { url in
      let source = try decodeAsset(for: url)
      return try source.interleavedSamples(sampleStride: sampleStride)
    }
  }

  func getAudioPcmChannelCount(path: String) throws -> Int {
    try fileAccess.withTemporaryAccess(for: path) { url in
      let source = try decodeAsset(for: url)
      return source.channelCount
    }
  }

  func getFingerprintPcm(path: String, maxDurationMs: Int) throws -> [String: Any] {
    try fileAccess.withTemporaryAccess(for: path) { url in
      let source = try decodeAsset(for: url)
      return [
        "samples": try source.interleavedSamples(sampleStride: 1, maxDurationMs: maxDurationMs),
        "sampleRate": Int(source.sampleRate.rounded()),
        "channels": source.channelCount,
      ]
    }
  }

  func prepareForFileWrite(path: String? = nil) throws {
    if let path {
      let normalizedPath = normalizedFilePath(path)
      if preparedAccessPaths.contains(normalizedPath) {
        return
      }

      if currentDeck.loadedURL?.path != normalizedPath {
        _ = try fileAccess.acquireAccess(for: normalizedPath)
        preparedAccessPaths.insert(normalizedPath)
        return
      }
    }

    guard let path = currentDeck.loadedURL?.path else { return }
    if preparedAccessPaths.contains(path) {
      return
    }

    let wasPlaying = currentDeck.isPlaying
    let positionMs = getCurrentPositionMs()
    let volume = latestVolume
    pendingEdit = PendingEdit(
      path: path,
      positionMs: positionMs,
      wasPlaying: wasPlaying,
      volume: volume
    )
    stopPlayback(releasingFile: true, preservePosition: true)
    _ = try fileAccess.acquireAccess(for: path)
    preparedAccessPaths.insert(path)
  }

  func prepareForFileWrite(paths: [String]) throws {
    let normalizedPaths = Self.normalizedUniquePaths(paths)
    for path in normalizedPaths {
      try prepareForFileWrite(path: path)
    }
  }

  func finishFileWrite(path: String? = nil) throws {
    debugPrint(
      "[AppleAudioEngine] finishFileWrite request path=\(path ?? "nil") " +
      "current=\(currentDeck.loadedURL?.path ?? "nil") pending=\(pendingEdit?.path ?? "nil")"
    )
    if let path {
      let normalizedPath = normalizedFilePath(path)
      if currentDeck.loadedURL?.path != normalizedPath {
        fileAccess.releaseAccess(for: normalizedPath)
        preparedAccessPaths.remove(normalizedPath)
        return
      }
    }

    guard let pendingEdit else { return }
    try load(path: pendingEdit.path)
    try seek(positionMs: pendingEdit.positionMs)
    try setVolume(pendingEdit.volume)
    if pendingEdit.wasPlaying {
      try play(fadeDurationMs: 0, targetVolume: pendingEdit.volume)
    }
    self.pendingEdit = nil
    preparedAccessPaths.remove(pendingEdit.path)
  }

  func finishFileWrite(paths: [String]) throws {
    let normalizedPaths = Self.normalizedUniquePaths(paths)
    for path in normalizedPaths {
      try finishFileWrite(path: path)
    }
  }

  func registerPersistentAccess(path: String) -> Bool {
    fileAccess.registerPersistentAccess(for: path)
  }

  func forgetPersistentAccess(path: String) {
    fileAccess.forgetPersistentAccess(for: path)
  }

  func hasPersistentAccess(path: String) -> Bool {
    fileAccess.hasPersistentAccess(for: path)
  }

  func listPersistentAccessPaths() -> [String] {
    fileAccess.listPersistentAccessPaths()
  }

  func beginScopedAccess(path: String) -> Bool {
    do {
      _ = try fileAccess.acquireAccess(for: path)
      return true
    } catch {
      return false
    }
  }

  func endScopedAccess(path: String) {
    fileAccess.releaseAccess(for: path)
  }

  func dispose() {
    debugPrint(
      "[AppleAudioEngine] dispose current=\(currentDeck.loadedURL?.path ?? "nil") " +
      "incoming=\(incomingDeck.loadedURL?.path ?? "nil")"
    )
    fadeTimer?.invalidate()
    fadeTimer = nil
    pendingEdit = nil
    preparedAccessPaths.removeAll()
    stopPlayback(releasingFile: true, preservePosition: false)
    fileAccess.releaseAllAccess()
    currentDeck.loadedURL = nil
    currentDeck.loadedFile = nil
    incomingDeck.loadedURL = nil
    incomingDeck.loadedFile = nil
  }

  func statusPayload(playbackState: String? = nil, error: String? = nil) -> [String: Any] {
    var payload: [String: Any] = [
      "playerId": "main",
      "state": playbackState ?? currentPlaybackState(),
      "position": getCurrentPositionMs(),
      "duration": getDurationMs(),
      "isPlaying": publicDeck()?.isPlaying ?? false,
      "volume": latestVolume,
      "updateTime": Int(Date().timeIntervalSince1970 * 1000),
    ]
    if let path = publicURL()?.path {
      payload["path"] = path
    }
    payload["error"] = error ?? NSNull()
    return payload
  }

  func setEqualizerConfig(_ config: AppleEqualizerConfig) {
    let sanitizedConfig = AppleEqualizerCodec.sanitized(config)
    latestEqualizerConfig = sanitizedConfig
    applyEqualizerConfig(sanitizedConfig)
  }

  func getEqualizerConfig() -> AppleEqualizerConfig {
    latestEqualizerConfig
  }

  func extractFingerprint(path: String, expectedChunks: Int) throws -> String? {
    // The Apple platform path currently keeps fingerprinting on the Dart/Rust side.
    // This native method exists so the plugin interface stays buildable.
    _ = path
    _ = expectedChunks
    return nil
  }

  func fitTrackMetadata(_ entry: [String: Any]) -> [String: Any] {
    entry
  }

  func fitTrackMetadataInLibrary(path: String) throws -> [String: Any] {
    _ = path
    return [:]
  }

  func deleteFromLibrary(path: String) throws {
    _ = path
  }

  func saveWaveform(path: String, data: [Double]) throws {
    _ = path
    _ = data
  }

  func addSilenceToWaveform(path: String, data: [Double]) throws {
    _ = path
    _ = data
  }

  private func emitPlayerState(playbackState: String? = nil, error: String? = nil) {
    onPlayerStateChanged?(playbackState, error)
  }

  private func currentPlaybackState() -> String {
    guard publicDeck() != nil else {
      return "IDLE"
    }
    return "READY"
  }

  private func normalizedFilePath(_ path: String) -> String {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("file://"), let url = URL(string: trimmed) {
      return url.standardizedFileURL.resolvingSymlinksInPath().path
    }
    return URL(fileURLWithPath: trimmed).standardizedFileURL.resolvingSymlinksInPath().path
  }

  private static func normalizedUniquePaths(_ paths: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for path in paths {
      let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
      let url: URL
      if trimmed.hasPrefix("file://"), let parsed = URL(string: trimmed) {
        url = parsed
      } else {
        url = URL(fileURLWithPath: trimmed)
      }
      let normalized = url.standardizedFileURL.resolvingSymlinksInPath().path
      if seen.insert(normalized).inserted {
        result.append(normalized)
      }
    }
    return result
  }

  private func publicDeck() -> PlaybackDeck? {
    if incomingDeck.isLoaded {
      return incomingDeck
    }
    if currentDeck.isLoaded {
      return currentDeck
    }
    return nil
  }

  private func publicURL() -> URL? {
    publicDeck()?.loadedURL
  }

  private func publicFile() -> AVAudioFile? {
    publicDeck()?.loadedFile
  }

  private func publicAnalysisFile() -> AVAudioFile? {
    publicDeck()?.analysisFile
  }

  private func publicFFmpegPCM() -> AppleFFmpegDecodedAudio? {
    publicDeck()?.ffmpegPCM
  }

  private func resetFftCaptureBuffer() {
    fftCaptureBuffer.clear()
    fftResultLock.lock()
    latestFftFrame = groupedZeroFrame()
    latestRawTapMagnitudes = Array(repeating: 0.0, count: fftBinCount)
    fftResultLock.unlock()
    fftTapCount = 0
    fftLastTapAtMs = nil
  }

  private func publicSampleSource() -> AppleAudioSampleSource? {
    if let url = publicURL(), publicFile() != nil {
      if let freshFile = try? AVAudioFile(forReading: url) {
        return .avFoundation(freshFile)
      }
    }
    if let decoded = publicFFmpegPCM() {
      return .ffmpeg(decoded)
    }
    if let stream = publicDeck()?.loadedFFmpegStream {
      return .ffmpegStream(stream)
    }
    return nil
  }

  private func publicSampleRate() -> Double {
    publicDeck()?.sampleRate ?? 44_100
  }

  private func playbackSampleRate() -> Double {
    let preferredRates = [
      deckMixerNode.outputFormat(forBus: 0).sampleRate,
      engine.mainMixerNode.outputFormat(forBus: 0).sampleRate,
      engine.outputNode.inputFormat(forBus: 0).sampleRate,
    ]
    for rate in preferredRates where rate > 0 {
      return rate
    }
    return publicSampleRate()
  }

  private func publicFrameCount() -> AVAudioFramePosition {
    publicDeck()?.frameCount ?? 0
  }

  private func publicChannelCount() -> Int {
    publicDeck()?.channelCount ?? 0
  }

  private func preferredLoadBackend(for url: URL) -> AppleAudioLoadBackend {
    let preferredExtension = url.pathExtension.lowercased()
    if avFoundationPreferredExtensions.contains(preferredExtension) {
      return .avFoundation
    }
    return .ffmpeg
  }

  private func decodeAsset(for url: URL) throws -> AppleAudioSampleSource {
    let startMs = currentTimestampMs()
    switch preferredLoadBackend(for: url) {
    case .avFoundation:
      do {
        let file = try AVAudioFile(forReading: url)
        debugPrint(
          "[AppleAudioEngine] avfoundation decode done path=\(url.path) elapsedMs=\(String(format: "%.1f", currentTimestampMs() - startMs))"
        )
        return .avFoundation(file)
      } catch {
        debugPrint(
          "[AppleAudioEngine] AVFoundation decode failed, falling back to ffmpeg path=\(url.path) error=\(error)"
        )
        let decoded = try AppleFFmpegDecoder.decode(path: url.path)
        debugPrint(
          "[AppleAudioEngine] ffmpeg fallback decode done path=\(url.path) elapsedMs=\(String(format: "%.1f", currentTimestampMs() - startMs))"
        )
        return .ffmpeg(decoded)
      }
    case .ffmpeg:
      let decoded = try AppleFFmpegDecoder.decode(path: url.path)
      debugPrint(
        "[AppleAudioEngine] ffmpeg decode backend selected path=\(url.path) elapsedMs=\(String(format: "%.1f", currentTimestampMs() - startMs))"
      )
      return .ffmpeg(decoded)
    }
  }

  private func loadAsset(into deck: PlaybackDeck, from url: URL) throws {
    let startMs = currentTimestampMs()
    switch preferredLoadBackend(for: url) {
    case .avFoundation:
      let source = try decodeAsset(for: url)
      switch source {
      case .avFoundation(let file):
        deck.sampleRate = file.processingFormat.sampleRate
        deck.loadedURL = url
        deck.loadedFile = file
        deck.analysisFile = try AVAudioFile(forReading: url)
        deck.loadedFFmpegPCM = nil
        deck.loadedFFmpegStream = nil
      case .ffmpeg(let decoded):
        // Some files can advertise AVFoundation support but still fail on Apple.
        // Keep the legacy fallback for those rare cases.
        let targetSampleRate = playbackSampleRate()
        let playbackPCM = try decoded.resampled(to: targetSampleRate)
        deck.sampleRate = playbackPCM.sampleRate
        deck.loadedURL = url
        deck.loadedFile = nil
        deck.analysisFile = nil
        deck.loadedFFmpegPCM = playbackPCM
        deck.loadedFFmpegStream = nil
      case .ffmpegStream(let stream):
        // Defensive fallback: decodeAsset currently never returns a stream in this branch,
        // but keep the switch exhaustive and preserve a usable PCM fallback if it ever does.
        throw NSError(
          domain: "AudioCore",
          code: 2,
          userInfo: [NSLocalizedDescriptionKey: "unexpected ffmpeg stream in avFoundation load path"]
        )
      }
    case .ffmpeg:
      let targetSampleRate = playbackSampleRate()
      let playbackStream = try AppleFFmpegStreamAudio(
        path: url.path,
        targetSampleRate: targetSampleRate,
        startFrame: 0
      )
      debugPrint(
        "[AppleAudioEngine] ffmpeg load prepared path=\(url.path) targetSampleRate=\(targetSampleRate) " +
        "sampleRate=\(playbackStream.sampleRate) frameCount=\(playbackStream.frameCount)"
      )
      deck.sampleRate = playbackStream.sampleRate
      deck.loadedURL = url
      deck.loadedFile = nil
      deck.analysisFile = nil
      deck.loadedFFmpegPCM = nil
      deck.loadedFFmpegStream = playbackStream
    }
    deck.playbackFramePosition = 0
    deck.isPlaybackScheduled = false
    deck.gain = 1.0
    deck.scheduledPCMBuffers.removeAll()
    resetFftCaptureBuffer()
    debugPrint(
      "[AppleAudioEngine] loadAsset done path=\(url.path) source=\(deck.sampleRate) " +
      "elapsedMs=\(String(format: "%.1f", currentTimestampMs() - startMs))"
    )
  }

  private func configureEngineIfNeeded() {
    guard !isEngineConfigured else { return }
    engine.attach(currentDeck.playerNode)
    engine.attach(incomingDeck.playerNode)
    engine.attach(deckMixerNode)
    engine.attach(equalizerNode)
    engine.connect(currentDeck.playerNode, to: deckMixerNode, format: nil)
    engine.connect(incomingDeck.playerNode, to: deckMixerNode, format: nil)
    engine.connect(deckMixerNode, to: equalizerNode, format: nil)
    engine.connect(equalizerNode, to: engine.mainMixerNode, format: nil)
    installFftCaptureTapIfNeeded()
    engine.prepare()
    isEngineConfigured = true
  }

  private func installFftCaptureTapIfNeeded() {
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

  private func handleFftTapBuffer(_ buffer: AVAudioPCMBuffer) {
    fftCaptureBuffer.append(buffer: buffer)
    refreshLatestFftFrame(frameLength: Int(buffer.frameLength))
  }

  private func refreshLatestFftFrame(frameLength: Int? = nil) {
    let monoSamples = fftCaptureBuffer.snapshot(lastFrames: fftSize)
    let magnitudes = computeMagnitudes(from: monoSamples)
    let grouped = groupMagnitudes(magnitudes)

    let tapNowMs = currentTimestampMs()
    fftTapCount &+= 1
    let tapDeltaMs = fftLastTapAtMs.map { tapNowMs - $0 }
    fftLastTapAtMs = tapNowMs

    let groupedDelta = meanAbsoluteDelta(grouped, comparedTo: latestFftFrame)
    let magnitudeDelta = meanAbsoluteDelta(magnitudes, comparedTo: latestRawTapMagnitudes)

    fftResultLock.lock()
    latestFftFrame = grouped
    latestRawTapMagnitudes = magnitudes
    fftResultLock.unlock()

    if fftTapCount <= 5 || fftTapCount % 30 == 0 {
      debugPrint(
        "[AppleAudioEngine] fft tap count=\(fftTapCount) " +
        "frameLength=\(frameLength.map(String.init) ?? "nil") " +
        "deltaMs=\(tapDeltaMs.map { String(format: "%.1f", $0) } ?? "nil") " +
        "groupedDelta=\(String(format: "%.6f", groupedDelta)) " +
        "magnitudeDelta=\(String(format: "%.6f", magnitudeDelta)) " +
        "first=\(grouped.first.map { String(format: "%.6f", $0) } ?? "nil")"
      )
    }
  }

  private func meanAbsoluteDelta(_ lhs: [Double], comparedTo rhs: [Double]) -> Double {
    let count = min(lhs.count, rhs.count)
    guard count > 0 else { return 0.0 }
    var total = 0.0
    for index in 0..<count {
      total += abs(lhs[index] - rhs[index])
    }
    return total / Double(count)
  }

  private func sampleFftFrameFromPlaybackPosition() throws -> [Double]? {
    guard let deck = publicDeck(), deck.isLoaded else { return nil }

    let totalFrameCount = deck.frameCount
    guard totalFrameCount > 0 else { return groupedZeroFrame() }

    let centerFrame = deck.currentPlaybackFramePosition()
    let halfWindow = AVAudioFramePosition(fftSize / 2)
    let desiredStart = max(0, centerFrame - halfWindow)
    let maxStart = max(0, totalFrameCount - AVAudioFramePosition(fftSize))
    let startFrame = min(desiredStart, maxStart)

    let monoSamples: [Float]
    if let analysisFile = publicAnalysisFile() {
      monoSamples = try Self.readMonoWindow(
        file: analysisFile,
        startFrame: startFrame,
        frameCount: fftSize
      )
    } else if let decoded = publicFFmpegPCM() {
      monoSamples = decoded
        .monoSamples(startFrame: startFrame, frameCount: fftSize)
        .map(Float.init)
    } else {
      return nil
    }

    let grouped = groupMagnitudes(computeMagnitudes(from: monoSamples))
    fftResultLock.lock()
    latestFftFrame = grouped
    fftResultLock.unlock()
    return grouped
  }

  private func applyEqualizerConfig(_ config: AppleEqualizerConfig) {
    let availableBandCount = equalizerNode.bands.count
    let userBandCount = min(AppleEqualizerDefaults.maxBands, max(0, availableBandCount - 1))
    let clampedBandCount = max(0, min(config.bandCount, userBandCount))
    let bandFrequencies = Self.bandCenterFrequencies(count: AppleEqualizerDefaults.maxBands)
    let maxBoostDb = Self.maxBoostDb(for: config, userBandCount: clampedBandCount)
    let compensatedPreampDb = config.preampDb - maxBoostDb

    equalizerNode.globalGain = Float(config.enabled ? compensatedPreampDb : 0.0)
    let eqBandwidth = Self.bandwidthInOctaves(forQ: AppleEqualizerDefaults.eqBandQ)
    let bassBandwidth = Self.bandwidthInOctaves(forQ: config.bassBoostQ)

    for index in 0..<userBandCount {
      let band = equalizerNode.bands[index]
      band.bypass = !config.enabled || index >= clampedBandCount
      band.filterType = .parametric
      band.frequency = Float(bandFrequencies[index])
      band.gain = index < config.bandGainsDb.count ? Float(config.bandGainsDb[index]) : 0.0
      band.bandwidth = eqBandwidth
    }

    if availableBandCount > userBandCount {
      let bassBand = equalizerNode.bands[userBandCount]
      bassBand.bypass = !config.enabled || abs(config.bassBoostDb) <= AppleEqualizerDefaults.epsilonGainDb
      bassBand.filterType = .resonantLowShelf
      bassBand.frequency = Float(config.bassBoostFrequencyHz)
      bassBand.gain = Float(config.bassBoostDb)
      bassBand.bandwidth = bassBandwidth
    }
  }

  private func startPlaybackIfNeeded(
    on deck: PlaybackDeck,
    from framePosition: AVAudioFramePosition,
    volume: Double
  ) throws {
    let startMs = currentTimestampMs()
    guard deck.isLoaded else {
      throw NSError(
        domain: "AudioCore",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "audio is not loaded"]
      )
    }

    configureEngineIfNeeded()
    applyEqualizerConfig(latestEqualizerConfig)

    if deck.playerNode.isPlaying {
      deck.playerNode.volume = Float(volume)
      return
    }

    let totalFrameCount = deck.frameCount
    let clampedFrame = max(0, min(framePosition, totalFrameCount))
    guard clampedFrame < totalFrameCount else {
      deck.playbackFramePosition = totalFrameCount
      return
    }

    if engine.isRunning == false {
      try engine.start()
    }

    deck.stopPlaybackNode()
    let generation = deck.playbackGeneration
    let scheduledPath = deck.loadedURL?.path
    if let stream = deck.loadedFFmpegStream {
      let scheduled = scheduleFFmpegPlayback(
        stream,
        on: deck,
        startingFrame: clampedFrame,
        generation: generation,
        expectedPath: scheduledPath
      )
      guard scheduled else {
        deck.playbackFramePosition = totalFrameCount
        return
      }
    } else if let decoded = deck.loadedFFmpegPCM {
      let scheduled = scheduleLegacyFFmpegPlayback(
        decoded,
        on: deck,
        startingFrame: clampedFrame,
        generation: generation,
        expectedPath: scheduledPath
      )
      guard scheduled else {
        deck.playbackFramePosition = totalFrameCount
        return
      }
    } else if let currentFile = deck.loadedFile {
      let framesRemaining = AVAudioFrameCount(currentFile.length - clampedFrame)
      schedulePlaybackSegment(
        currentFile,
        on: deck,
        startingFrame: clampedFrame,
        frameCount: framesRemaining,
        generation: generation,
        expectedPath: scheduledPath
      )
    }
    deck.playbackFramePosition = clampedFrame
    deck.isPlaybackScheduled = true
    deck.playerNode.volume = Float(volume)
    deck.playerNode.play()
    debugPrint(
      "[AppleAudioEngine] startPlaybackIfNeeded done path=\(deck.loadedURL?.path ?? "nil") " +
      "frame=\(clampedFrame) elapsedMs=\(String(format: "%.1f", currentTimestampMs() - startMs))"
    )
  }

  private func schedulePlaybackSegment(
    _ file: AVAudioFile,
    on deck: PlaybackDeck,
    startingFrame: AVAudioFramePosition,
    frameCount: AVAudioFrameCount,
    generation: UInt64,
    expectedPath: String?
  ) {
    if #available(macOS 10.13, iOS 11.0, *) {
      deck.playerNode.scheduleSegment(
        file,
        startingFrame: startingFrame,
        frameCount: frameCount,
        at: nil,
        completionCallbackType: .dataPlayedBack,
        completionHandler: { [weak self] _ in
          self?.handlePlaybackCompleted(
            deck: deck,
            generation: generation,
            expectedPath: expectedPath
          )
        }
      )
      return
    }

    deck.playerNode.scheduleSegment(
      file,
      startingFrame: startingFrame,
      frameCount: frameCount,
      at: nil,
      completionHandler: { [weak self] in
        self?.scheduleLegacyPlaybackCompletionCheck(
          deck: deck,
          generation: generation,
          expectedPath: expectedPath,
          attempt: 0
        )
      }
    )
  }

  private func scheduleFFmpegPlayback(
    _ stream: AppleFFmpegStreamAudio,
    on deck: PlaybackDeck,
    startingFrame: AVAudioFramePosition,
    generation: UInt64,
    expectedPath: String?
  ) -> Bool {
    let startMs = currentTimestampMs()
    let totalFrames = stream.frameCount
    let startFrame = max(0, min(startingFrame, totalFrames))
    do {
      try stream.ensureOpen(targetSampleRate: deck.sampleRate, startFrame: startFrame)
    } catch {
      debugPrint(
        "[AppleAudioEngine] ffmpeg stream reopen failed path=\(deck.loadedURL?.path ?? "nil") " +
        "error=\(error.localizedDescription)"
      )
      handlePlaybackCompleted(deck: deck, generation: generation, expectedPath: expectedPath)
      return false
    }

    var nextFrameToSchedule = startFrame
    deck.scheduledPCMBuffers.removeAll()

    debugPrint(
      "[AppleAudioEngine] ffmpeg schedule start path=\(deck.loadedURL?.path ?? "nil") " +
      "startFrame=\(startFrame) totalFrames=\(totalFrames) lookahead=\(ffmpegPlaybackLookaheadBuffers)"
    )

    func scheduleNextBuffer() -> Bool {
      guard nextFrameToSchedule < totalFrames else {
        return false
      }

      let chunkBuffer: AppleFFmpegDecodedAudio
      do {
        guard let chunk = try stream.nextChunk(maxFrames: ffmpegScheduleChunkFrames) else {
          return false
        }
        chunkBuffer = chunk
      } catch {
        debugPrint(
          "[AppleAudioEngine] ffmpeg stream chunk decode failed path=\(deck.loadedURL?.path ?? "nil") " +
          "error=\(error.localizedDescription)"
        )
        return false
      }
      guard chunkBuffer.frameCount > 0 else {
        return false
      }

      let bufferStart = nextFrameToSchedule
      let buffer = chunkBuffer.buildPCMBuffer(startFrame: 0, maxFrames: Int(chunkBuffer.frameCount))
      guard let buffer else {
        return false
      }
      let bufferFrameCount = AVAudioFramePosition(buffer.frameLength)
      guard bufferFrameCount > 0 else {
        return false
      }

      nextFrameToSchedule = min(totalFrames, bufferStart + bufferFrameCount)
      let isLastBuffer = nextFrameToSchedule >= totalFrames
      if deck.scheduledPCMBuffers.count >= ffmpegPlaybackLookaheadBuffers {
        deck.scheduledPCMBuffers.removeFirst()
      }
      deck.scheduledPCMBuffers.append(buffer)

      let completion: (AVAudioPCMBuffer) -> Void = { [weak self] _ in
        DispatchQueue.main.async {
          guard let self = self else { return }
          guard deck.playbackGeneration == generation, deck.isPlaybackScheduled else {
            return
          }
          if isLastBuffer {
            self.handlePlaybackCompleted(
              deck: deck,
              generation: generation,
              expectedPath: expectedPath
            )
            return
          }

          self.ffmpegPlaybackQueue.async {
            if !deck.scheduledPCMBuffers.isEmpty {
              deck.scheduledPCMBuffers.removeFirst()
            }
            if !scheduleNextBuffer() {
              debugPrint(
                "[AppleAudioEngine] ffmpeg schedule refill failed path=\(deck.loadedURL?.path ?? "nil") " +
                "generation=\(generation)"
              )
              DispatchQueue.main.async {
                self.handlePlaybackCompleted(
                  deck: deck,
                  generation: generation,
                  expectedPath: expectedPath
                )
              }
            }
          }
        }
      }

      if #available(macOS 10.13, iOS 11.0, *) {
        deck.playerNode.scheduleBuffer(
          buffer,
          at: nil,
          options: [],
          completionCallbackType: isLastBuffer ? .dataPlayedBack : .dataConsumed,
          completionHandler: { _ in
            completion(buffer)
          }
        )
      } else {
        deck.playerNode.scheduleBuffer(buffer, completionHandler: {
          completion(buffer)
        })
      }

      return true
    }

    var scheduledAny = false
    ffmpegPlaybackQueue.sync {
      for _ in 0..<ffmpegPlaybackLookaheadBuffers {
        guard scheduleNextBuffer() else {
          break
        }
        scheduledAny = true
      }
    }

    guard scheduledAny else {
      handlePlaybackCompleted(deck: deck, generation: generation, expectedPath: expectedPath)
      return false
    }
    debugPrint(
      "[AppleAudioEngine] ffmpeg schedule initial queued=\(deck.scheduledPCMBuffers.count) " +
      "elapsedMs=\(String(format: "%.1f", currentTimestampMs() - startMs))"
    )
    return true
  }

  private func scheduleLegacyFFmpegPlayback(
    _ decoded: AppleFFmpegDecodedAudio,
    on deck: PlaybackDeck,
    startingFrame: AVAudioFramePosition,
    generation: UInt64,
    expectedPath: String?
  ) -> Bool {
    let buffers = decoded.buildBufferQueue(
      startFrame: startingFrame,
      chunkFrames: ffmpegScheduleChunkFrames
    )
    deck.scheduledPCMBuffers = buffers

    guard !buffers.isEmpty else {
      handlePlaybackCompleted(deck: deck, generation: generation, expectedPath: expectedPath)
      return false
    }

    for (index, buffer) in buffers.enumerated() {
      let isLastBuffer = index == buffers.count - 1
      if #available(macOS 10.13, iOS 11.0, *) {
        deck.playerNode.scheduleBuffer(
          buffer,
          at: nil,
          options: [],
          completionCallbackType: .dataPlayedBack,
          completionHandler: { [weak self] _ in
            if isLastBuffer {
              self?.handlePlaybackCompleted(
                deck: deck,
                generation: generation,
                expectedPath: expectedPath
              )
            }
          }
        )
      } else {
        deck.playerNode.scheduleBuffer(buffer, completionHandler: { [weak self] in
          if isLastBuffer {
            self?.handlePlaybackCompleted(
              deck: deck,
              generation: generation,
              expectedPath: expectedPath
            )
          }
        })
      }
    }
    return true
  }

  private func scheduleLegacyPlaybackCompletionCheck(
    deck: PlaybackDeck,
    generation: UInt64,
    expectedPath: String?,
    attempt: Int
  ) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
      self?.verifyLegacyPlaybackCompletion(
        deck: deck,
        generation: generation,
        expectedPath: expectedPath,
        attempt: attempt
      )
    }
  }

  private func verifyLegacyPlaybackCompletion(
    deck: PlaybackDeck,
    generation: UInt64,
    expectedPath: String?,
    attempt: Int
  ) {
    guard deck.playbackGeneration == generation, deck.isPlaybackScheduled else {
      return
    }
    guard deck.loadedURL?.path == expectedPath else {
      return
    }
    guard let currentFile = deck.loadedFile else {
      return
    }

    let currentFrame = deck.currentPlaybackFramePosition()
    let toleranceFrames = max(AVAudioFramePosition(deck.sampleRate * 0.1), 4096)
    let nearEndFrame = max(0, currentFile.length - toleranceFrames)
    let isNearEnd = currentFrame >= nearEndFrame

    if isNearEnd || !deck.playerNode.isPlaying || attempt >= 40 {
      handlePlaybackCompleted(deck: deck, generation: generation, expectedPath: expectedPath)
      return
    }

    scheduleLegacyPlaybackCompletionCheck(
      deck: deck,
      generation: generation,
      expectedPath: expectedPath,
      attempt: attempt + 1
    )
  }

  private func handlePlaybackCompleted(
    deck: PlaybackDeck,
    generation: UInt64,
    expectedPath: String?
  ) {
    let completedPath = deck.loadedURL?.path
    debugPrint(
      "[AppleAudioEngine] handlePlaybackCompleted fired path=\(completedPath ?? "nil") " +
      "expected=\(expectedPath ?? "nil") generation=\(generation) deckGen=\(deck.playbackGeneration) scheduled=\(deck.isPlaybackScheduled) " +
      "public=\(publicURL()?.path ?? "nil")"
    )
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      guard deck.playbackGeneration == generation, deck.isPlaybackScheduled else {
        debugPrint(
          "[AppleAudioEngine] handlePlaybackCompleted ignored stale callback path=\(completedPath ?? "nil") " +
          "generation=\(generation) deckGen=\(deck.playbackGeneration) scheduled=\(deck.isPlaybackScheduled)"
        )
        return
      }
      if let expectedPath, deck.loadedURL?.path != expectedPath {
        debugPrint(
          "[AppleAudioEngine] handlePlaybackCompleted ignored expectedMismatch expected=\(expectedPath) " +
          "current=\(deck.loadedURL?.path ?? "nil") public=\(self.publicURL()?.path ?? "nil")"
        )
        return
      }
      if let completedPath, self.publicURL()?.path != completedPath {
        debugPrint(
          "[AppleAudioEngine] handlePlaybackCompleted ignored publicChanged completed=\(completedPath) " +
          "public=\(self.publicURL()?.path ?? "nil")"
        )
        return
      }
      if let currentFile = deck.loadedFile {
        deck.playbackFramePosition = currentFile.length
      } else if let stream = deck.loadedFFmpegStream {
        deck.playbackFramePosition = stream.frameCount
      }
      // Ensure the native node reports a stopped state so the Dart layer can
      // reliably treat this as a completed track and advance the queue.
      deck.stopPlaybackNode()
      deck.isPlaybackScheduled = false
      deck.scheduledPCMBuffers.removeAll()
      deck.loadedFFmpegStream?.close()
      self.emitPlayerState(playbackState: "ENDED")
    }
  }

  private func stopPlayback(releasingFile: Bool, preservePosition: Bool) {
    debugPrint(
      "[AppleAudioEngine] stopPlayback releasingFile=\(releasingFile) preservePosition=\(preservePosition) " +
      "current=\(currentDeck.loadedURL?.path ?? "nil") incoming=\(incomingDeck.loadedURL?.path ?? "nil")"
    )
    fadeTimer?.invalidate()
    fadeTimer = nil
    fadeGeneration &+= 1

    if preservePosition {
      if let deck = publicDeck() {
        deck.playbackFramePosition = deck.currentPlaybackFramePosition()
      }
    }

    if releasingFile {
      if let currentURL = currentDeck.loadedURL {
        fileAccess.releaseAccess(for: currentURL)
      }
      if let incomingURL = incomingDeck.loadedURL {
        fileAccess.releaseAccess(for: incomingURL)
      }
    }

    currentDeck.clear(releasingFile: releasingFile)
    incomingDeck.clear(releasingFile: releasingFile)
    if releasingFile {
      resetFftCaptureBuffer()
    }

    if !releasingFile {
      currentDeck.loadedFFmpegStream?.close()
      incomingDeck.loadedFFmpegStream?.close()
    }

    if releasingFile {
      currentDeck.playbackFramePosition = 0
      incomingDeck.playbackFramePosition = 0
    }
  }

  private func pausePlayback(preservePosition: Bool) {
    debugPrint(
      "[AppleAudioEngine] pausePlayback preservePosition=\(preservePosition) " +
      "current=\(currentDeck.loadedURL?.path ?? "nil") incoming=\(incomingDeck.loadedURL?.path ?? "nil")"
    )
    fadeTimer?.invalidate()
    fadeTimer = nil
    fadeGeneration &+= 1

    if preservePosition {
      if currentDeck.isLoaded {
        currentDeck.playbackFramePosition = currentDeck.currentPlaybackFramePosition()
      }
      if incomingDeck.isLoaded {
        incomingDeck.playbackFramePosition = incomingDeck.currentPlaybackFramePosition()
      }
    }

    if currentDeck.isLoaded {
      currentDeck.playerNode.pause()
      currentDeck.scheduledPCMBuffers.removeAll()
    }
    if incomingDeck.isLoaded {
      incomingDeck.playerNode.pause()
      incomingDeck.scheduledPCMBuffers.removeAll()
    }

    currentDeck.loadedFFmpegStream?.close()
    incomingDeck.loadedFFmpegStream?.close()

    // Emit the settled paused state only after the node has actually paused,
    // so the Dart layer does not keep animating against a stale playing state.
    emitPlayerState(playbackState: "PAUSED")
  }

  private func restoreDeckVolumes() {
    if currentDeck.isLoaded {
      currentDeck.playerNode.volume = Float((latestVolume * currentDeck.gain).clamped(to: 0.0...1.0))
    }
    if incomingDeck.isLoaded {
      incomingDeck.playerNode.volume = Float((latestVolume * incomingDeck.gain).clamped(to: 0.0...1.0))
    }
  }

  private func releaseCurrentAccessIfNeeded() {
    guard let currentURL = currentDeck.loadedURL else { return }
    fileAccess.releaseAccess(for: currentURL)
    currentDeck.loadedURL = nil
  }

  private func startCrossfade(path: String, durationMs: Int, positionMs: Int?) throws {
    debugPrint(
      "[AppleAudioEngine] startCrossfade path=\(path) durationMs=\(durationMs) " +
      "positionMs=\(positionMs.map(String.init) ?? "nil") current=\(currentDeck.loadedURL?.path ?? "nil") " +
      "incoming=\(incomingDeck.loadedURL?.path ?? "nil")"
    )
    guard currentDeck.loadedFile != nil || currentDeck.loadedFFmpegStream != nil else {
      try load(path: path)
      try play(fadeDurationMs: durationMs, targetVolume: latestVolume)
      return
    }

    configureEngineIfNeeded()
    applyEqualizerConfig(latestEqualizerConfig)

    if incomingDeck.loadedURL != nil {
      if let oldIncomingURL = incomingDeck.loadedURL {
        fileAccess.releaseAccess(for: oldIncomingURL)
      }
      incomingDeck.clear(releasingFile: true)
    }

    let incomingURL = try fileAccess.acquireAccess(for: path)
    try loadAsset(into: incomingDeck, from: incomingURL)
    let startFrame: AVAudioFramePosition
    if let positionMs, positionMs > 0 {
      let targetFrame = framePosition(forMilliseconds: positionMs, sampleRate: incomingDeck.sampleRate)
      startFrame = max(0, min(targetFrame, incomingDeck.frameCount))
    } else {
      startFrame = 0
    }
    incomingDeck.playbackFramePosition = startFrame
    incomingDeck.gain = 0.0

    currentDeck.playbackFramePosition = currentDeck.currentPlaybackFramePosition()
    currentDeck.gain = 1.0
    currentDeck.playerNode.volume = Float(latestVolume)

    try startPlaybackIfNeeded(on: incomingDeck, from: startFrame, volume: 0.0)
    incomingDeck.playerNode.volume = 0.0
    currentDeck.playerNode.volume = Float(latestVolume)

    fadeTimer?.invalidate()
    fadeTimer = nil
    fadeGeneration &+= 1
    let generation = fadeGeneration
    let steps = max(1, durationMs / 16)
    var step = 0
    let stepDurationSeconds = Double(durationMs) / Double(steps) / 1000.0

    fadeTimer = Timer.scheduledTimer(withTimeInterval: stepDurationSeconds, repeats: true) { [weak self] timer in
      guard let self = self else {
        timer.invalidate()
        return
      }

      guard self.fadeGeneration == generation else {
        timer.invalidate()
        return
      }

      step += 1
      let progress = min(1.0, Double(step) / Double(steps))
      let currentGain = 1.0 - progress
      let incomingGain = progress

      self.currentDeck.gain = currentGain
      self.incomingDeck.gain = incomingGain
      self.currentDeck.playerNode.volume = Float((self.latestVolume * currentGain).clamped(to: 0.0...1.0))
      self.incomingDeck.playerNode.volume = Float((self.latestVolume * incomingGain).clamped(to: 0.0...1.0))

      if progress >= 1.0 {
        timer.invalidate()
        self.fadeTimer = nil
        self.settleCrossfade()
      }
    }

    RunLoop.main.add(fadeTimer!, forMode: .common)
  }

  private func settleCrossfade() {
    debugPrint(
      "[AppleAudioEngine] settleCrossfade start current=\(currentDeck.loadedURL?.path ?? "nil") " +
      "incoming=\(incomingDeck.loadedURL?.path ?? "nil")"
    )
    guard incomingDeck.loadedFile != nil || incomingDeck.loadedFFmpegStream != nil else { return }

    if let oldURL = currentDeck.loadedURL {
      fileAccess.releaseAccess(for: oldURL)
    }

    swap(&currentDeck.playerNode, &incomingDeck.playerNode)
    swap(&currentDeck.loadedURL, &incomingDeck.loadedURL)
    swap(&currentDeck.loadedFile, &incomingDeck.loadedFile)
    swap(&currentDeck.analysisFile, &incomingDeck.analysisFile)
    swap(&currentDeck.loadedFFmpegPCM, &incomingDeck.loadedFFmpegPCM)
    swap(&currentDeck.loadedFFmpegStream, &incomingDeck.loadedFFmpegStream)
    swap(&currentDeck.sampleRate, &incomingDeck.sampleRate)
    swap(&currentDeck.playbackFramePosition, &incomingDeck.playbackFramePosition)
    swap(&currentDeck.isPlaybackScheduled, &incomingDeck.isPlaybackScheduled)
    swap(&currentDeck.gain, &incomingDeck.gain)
    swap(&currentDeck.scheduledPCMBuffers, &incomingDeck.scheduledPCMBuffers)

    currentDeck.gain = 1.0
    currentDeck.playerNode.volume = Float(latestVolume)
    currentDeck.playbackFramePosition = currentDeck.currentPlaybackFramePosition()

    incomingDeck.clear(releasingFile: true)
    if let currentURL = currentDeck.loadedURL {
      preparedAccessPaths.remove(currentURL.path)
    }
    debugPrint(
      "[AppleAudioEngine] settleCrossfade done current=\(currentDeck.loadedURL?.path ?? "nil") " +
      "incoming=\(incomingDeck.loadedURL?.path ?? "nil")"
    )
  }

  private func fadeVolume(
    from: Double,
    to: Double,
    durationMs: Int,
    update: @escaping (Double) -> Void,
    completion: @escaping () -> Void
  ) {
    fadeTimer?.invalidate()
    fadeGeneration &+= 1
    let generation = fadeGeneration
    let steps = max(1, durationMs / 16)
    var step = 0
    let stepDurationSeconds = Double(durationMs) / Double(steps) / 1000.0
    fadeTimer = Timer.scheduledTimer(
      withTimeInterval: stepDurationSeconds,
      repeats: true
    ) { [weak self] timer in
      guard let self = self else {
        timer.invalidate()
        return
      }
      guard self.fadeGeneration == generation else {
        timer.invalidate()
        return
      }
      step += 1
      let progress = min(1.0, Double(step) / Double(steps))
      let nextVolume = from + ((to - from) * progress)
      update(nextVolume.clamped(to: 0.0...1.0))
      if progress >= 1.0 {
        timer.invalidate()
        self.fadeTimer = nil
        completion()
      }
    }
    RunLoop.main.add(fadeTimer!, forMode: .common)
  }

  private func framePosition(forMilliseconds milliseconds: Int, sampleRate: Double) -> AVAudioFramePosition {
    guard sampleRate > 0 else { return 0 }
    let frame = (Double(milliseconds) / 1000.0) * sampleRate
    return AVAudioFramePosition(frame.rounded(.down))
  }

  private func frameCountToMilliseconds(_ frameCount: AVAudioFramePosition, sampleRate: Double) -> Int {
    framePositionToMilliseconds(frameCount, sampleRate: sampleRate)
  }

  private func framePositionToMilliseconds(_ framePosition: AVAudioFramePosition, sampleRate: Double) -> Int {
    guard sampleRate > 0 else { return 0 }
    return max(0, Int(((Double(framePosition) / sampleRate) * 1000.0).rounded()))
  }

  private func groupedZeroFrame() -> [Double] {
    Array(repeating: 0.0, count: fftGroupingConfig.frequencyGroups)
  }

  fileprivate static func readInterleavedPCM(
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

  fileprivate static func readFFmpegStreamInterleavedPCM(
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

  fileprivate static func readInterleavedPCM(
    url: URL,
    sampleStride: Int,
    maxDurationMs: Int = 0
  ) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    return try Self.readInterleavedPCM(file: file, sampleStride: sampleStride, maxDurationMs: maxDurationMs)
  }

  private func mixToMonoSamples(_ pcm: [Float], channels: Int) -> [Double] {
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

  private func processWaveform(samples: [Double], expectedChunks: Int) -> [Double] {
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

  private func computeRms(samples: [Double], start: Int, end: Int) -> Double {
    guard end > start else { return 0.0 }
    var sum = 0.0
    for index in start..<end {
      let sample = samples[index]
      sum += sample * sample
    }
    return sqrt(sum / Double(end - start))
  }

  private func roundWaveformPrecision(_ value: Double) -> Double {
    return (value * waveformPrecisionScale).rounded() / waveformPrecisionScale
  }

  fileprivate static func readMonoWindow(
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

  fileprivate static func readFFmpegStreamMonoWindow(
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

  fileprivate static func readMonoWindow(
    url: URL,
    startFrame: AVAudioFramePosition,
    frameCount: Int
  ) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    return try Self.readMonoWindow(file: file, startFrame: startFrame, frameCount: frameCount)
  }

  private func computeMagnitudes(from samples: [Float]) -> [Double] {
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

  private func groupMagnitudes(_ magnitudes: [Double]) -> [Double] {
    let groups = max(1, fftGroupingConfig.frequencyGroups)
    guard !magnitudes.isEmpty else {
      return groupedZeroFrame()
    }
    guard magnitudes.count > 1 else {
      return Array(repeating: magnitudes.first ?? 0.0, count: groups)
    }
    if groups == magnitudes.count && fftGroupingConfig.skipHighFrequencyGroups == 0 {
      return magnitudes
    }

    let totalGroups = min(max(groups + fftGroupingConfig.skipHighFrequencyGroups, groups), 512)
    let binCount = magnitudes.count
    var output = Array(repeating: 0.0, count: groups)

    var boundaries = Array(repeating: 1, count: totalGroups + 1)
    boundaries[0] = 1
    boundaries[totalGroups] = binCount
    if totalGroups > 1 {
      for index in 1..<totalGroups {
        let t = Double(index) / Double(totalGroups)
        let position = pow(Double(binCount), t) - 1.0
        boundaries[index] = Int(position.rounded())
          .clamped(to: 1...(binCount - 1))
      }
    }

    if totalGroups > 1 {
      for index in 1...totalGroups {
        if boundaries[index] <= boundaries[index - 1] {
          boundaries[index] = min(boundaries[index - 1] + 1, binCount)
        }
      }
    }
    boundaries[totalGroups] = binCount

    for group in 0..<groups {
      let start = boundaries[group]
      let end = boundaries[group + 1]
      guard end > start else {
        output[group] = 0.0
        continue
      }

      var acc = 0.0
      var peak = 0.0
      var square = 0.0
      for index in start..<end {
        let value = magnitudes[index]
        if value > peak {
          peak = value
        }
        acc += value
        square += value * value
      }

      let count = Double(end - start)
      switch fftGroupingConfig.aggregationMode {
      case .peak:
        output[group] = peak
      case .mean:
        output[group] = acc / count
      case .rms:
        output[group] = sqrt(square / count)
      }
    }

    return output
  }

  private static func bandwidthInOctaves(forQ q: Double) -> Float {
    let safeQ = max(q, 0.0001)
    let root = (1.0 + sqrt(1.0 + 4.0 * safeQ * safeQ)) / (2.0 * safeQ)
    let bandwidth = 2.0 * log2(root)
    return Float(max(0.05, min(bandwidth, 6.0)))
  }

  private static func maxBoostDb(for config: AppleEqualizerConfig, userBandCount: Int) -> Double {
    var maxBoostDb = max(0.0, config.bassBoostDb)
    for index in 0..<min(userBandCount, config.bandGainsDb.count) {
      maxBoostDb = max(maxBoostDb, config.bandGainsDb[index])
    }
    return maxBoostDb
  }

  private static func bandCenterFrequencies(count: Int) -> [Double] {
    let safeCount = max(count, 1)
    if safeCount == 1 {
      return [1000.0]
    }

    let minFrequency = AppleEqualizerDefaults.minCenterFrequencyHz
    let maxFrequency = AppleEqualizerDefaults.maxCenterFrequencyHz
    let ratio = maxFrequency / minFrequency
    return (0..<safeCount).map { index in
      let exponent = Double(index) / Double(safeCount - 1)
      return minFrequency * pow(ratio, exponent)
    }
  }

}
