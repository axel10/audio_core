import Accelerate
import AVFoundation
import Foundation
import os

import SFBAudioEngine

final class AppleAudioEngine: NSObject {
  struct PendingEdit {
    let path: String
    let positionMs: Int
    let wasPlaying: Bool
    let volume: Double
  }

  private enum SlotKind {
    case primary
    case secondary

    var opposite: SlotKind {
      switch self {
      case .primary:
        return .secondary
      case .secondary:
        return .primary
      }
    }
  }

  private final class PlaybackSlot {
    var url: URL?
    var gain: Double = 1.0
    var storedPositionMs: Int = 0

#if canImport(SFBAudioEngine)
    let player = AudioPlayer()
    var file: AudioFile?
#else
    var player: AVAudioPlayer?
    var durationOverrideMs: Int = 0
#endif

    var isLoaded: Bool {
      url != nil
    }

    var isPlaying: Bool {
#if canImport(SFBAudioEngine)
      player.isPlaying
#else
      player?.isPlaying ?? false
#endif
    }

    var isPaused: Bool {
#if canImport(SFBAudioEngine)
      player.isPaused
#else
      (player != nil) && !(player?.isPlaying ?? false) && currentPositionMs > 0
#endif
    }

    var sampleRate: Double {
#if canImport(SFBAudioEngine)
      file?.properties.sampleRate ?? 44_100
#else
      player?.sampleRate ?? 44_100
#endif
    }

    var frameLength: AVAudioFramePosition {
#if canImport(SFBAudioEngine)
      file?.properties.frameLength ?? 0
#else
      AVAudioFramePosition(durationMs) // Placeholder for compatibility.
#endif
    }

    var durationMs: Int {
#if canImport(SFBAudioEngine)
      let durationSeconds = file?.properties.duration ?? player.totalTime ?? 0
      return max(0, Int((durationSeconds * 1000.0).rounded()))
#else
      if durationOverrideMs > 0 {
        return durationOverrideMs
      }
      return max(0, Int((player?.duration ?? 0) * 1000.0))
#endif
    }

    var currentPositionMs: Int {
#if canImport(SFBAudioEngine)
      if let currentTime = player.currentTime {
        return max(0, Int((currentTime * 1000.0).rounded()))
      }
      return max(0, storedPositionMs)
#else
      if let player {
        return max(0, Int((player.currentTime * 1000.0).rounded()))
      }
      return max(0, storedPositionMs)
#endif
    }

    var currentVolume: Double {
#if canImport(SFBAudioEngine)
      Double(player.mainMixerNode.outputVolume)
#else
      Double(player?.volume ?? 0.0)
#endif
    }

    func load(url: URL) throws {
      stop()
      self.url = url
      storedPositionMs = 0
#if canImport(SFBAudioEngine)
      file = try? AudioFile(readingPropertiesAndMetadataFrom: url)
      _ = try player.enqueue(url, immediate: true)
      applyBaseVolume(1.0)
#else
      player = try AVAudioPlayer(contentsOf: url)
      player?.prepareToPlay()
      durationOverrideMs = max(0, Int((player?.duration ?? 0) * 1000.0))
      applyBaseVolume(1.0)
#endif
    }

    func play() throws {
#if canImport(SFBAudioEngine)
      switch player.playbackState {
      case .paused:
        _ = player.resume()
      case .playing:
        break
      case .stopped:
        _ = try player.play()
      @unknown default:
        _ = try player.play()
      }
#else
      _ = player?.play()
#endif
    }

    func pause() {
#if canImport(SFBAudioEngine)
      _ = player.pause()
#else
      player?.pause()
#endif
      storedPositionMs = currentPositionMs
    }

    func stop() {
#if canImport(SFBAudioEngine)
      player.stop()
#else
      player?.stop()
      player?.currentTime = 0
#endif
      storedPositionMs = 0
      gain = 1.0
    }

    func seek(positionMs: Int) throws {
      let clamped = max(0, positionMs)
      storedPositionMs = clamped
#if canImport(SFBAudioEngine)
      _ = player.seek(time: Double(clamped) / 1000.0)
#else
      player?.currentTime = Double(clamped) / 1000.0
#endif
    }

    func applyBaseVolume(_ baseVolume: Double) {
      let next = Float((baseVolume * gain).clamped(to: 0.0...1.0))
#if canImport(SFBAudioEngine)
      player.mainMixerNode.outputVolume = next
#else
      player?.volume = next
#endif
    }

    func applyVolume(_ volume: Double) {
      let next = Float(volume.clamped(to: 0.0...1.0))
#if canImport(SFBAudioEngine)
      player.mainMixerNode.outputVolume = next
#else
      player?.volume = next
#endif
    }

    func clear() {
      stop()
      url = nil
      storedPositionMs = 0
#if canImport(SFBAudioEngine)
      file = nil
#else
      player = nil
      durationOverrideMs = 0
#endif
    }
  }

  private let fileAccess: SecurityScopedFileAccessCoordinator
  private let stateQueue = DispatchQueue(label: "audio_core.apple.engine.state", qos: .userInitiated)
  private let stateQueueKey = DispatchSpecificKey<Void>()
  private let preparedAccessPathsLock = NSLock()
  private var preparedAccessPaths = Set<String>()
  private let primarySlot = PlaybackSlot()
  private let secondarySlot = PlaybackSlot()
  private var activeSlotKind: SlotKind = .primary
  private var pendingEdit: PendingEdit?
  private var latestVolume: Double = 1.0
  private var latestEqualizerConfig = AppleEqualizerCodec.defaultConfig()
  private var fadeTimer: DispatchSourceTimer?
  private var fadeGeneration: UInt64 = 0
  private var seekDebounceTimer: DispatchSourceTimer?
  private var pendingSeekPositionMs: Int?
  private let fftSize = 1024
  private let fftBinCount = 512
  private let fftLog2Size: vDSP_Length = 9
  private let fftHopSize = 512
  private let fftFrameQueueCapacity = 24
  private let fftProcessingQueue = DispatchQueue(
    label: "audio_core.apple.fft.processing",
    qos: .userInitiated
  )
  private let fftCaptureBuffer = AppleFftRingBuffer(capacity: 16_384)
  private let fftResultLock = NSLock()
  private let fftSetup: FFTSetup?
  private let fftWorkspace: AppleFftWorkspace
  private var latestRawFft: [Double]
  private var latestRawTapMagnitudes: [Double]
  private var fftAnalysisRemainder: [Float] = []
  private var pendingFftFrames: [[Double]] = []
  private var fftTapCount: Int = 0
  private var fftLastTapAtMs: Double?
  private var fftLastFetchAtMs: Double?
  private var fftTapSlotKind: SlotKind?
  private var isFftTapInstalled = false
  private var fftProcessingGeneration: UInt64 = 0
  private let waveformRmsWindowsPerChunk = 8
  private let waveformPrecisionScale = 100.0
  private var fftGroupingConfig = AppleFftGroupingConfig()

  var onPlayerStateChanged: ((String?, String?) -> Void)?

  init(fileAccess: SecurityScopedFileAccessCoordinator) {
    self.fileAccess = fileAccess
    self.fftSetup = vDSP_create_fftsetup(fftLog2Size, FFTRadix(kFFTRadix2))
    self.fftWorkspace = AppleFftWorkspace(fftSize: fftSize)
    self.latestRawFft = Array(repeating: 0.0, count: fftBinCount)
    self.latestRawTapMagnitudes = Array(repeating: 0.0, count: fftBinCount)
    super.init()
    stateQueue.setSpecific(key: stateQueueKey, value: ())
    installDelegates()
    applyEqualizerConfig(latestEqualizerConfig)
  }

  deinit {
    cancelTimers()
    removeFftCaptureTap()
    if let fftSetup {
      vDSP_destroy_fftsetup(fftSetup)
    }
    releaseAllAccess()
  }

  func ensureReady() {
    // The player is created eagerly so the channel contract stays simple.
  }

  func load(path: String) throws {
    try syncOnStateQueue {
      let normalizedPath = normalizedFilePath(path)
      let url = try fileAccess.acquireAccess(for: normalizedPath)
      cancelTimers()
      stopSlots(releasingFile: true, preservePosition: false)
      let slot = activeSlot
      try slot.load(url: url)
      slot.applyBaseVolume(latestVolume)
      refreshFftCapture(for: activeSlotKind)
    }
  }

  func crossfade(path: String, durationMs: Int, positionMs: Int? = nil) throws {
    try syncOnStateQueue {
      let fadeDurationMs = max(0, durationMs)
      guard let outgoingSlot = publicSlot(), outgoingSlot.isLoaded, outgoingSlot.isPlaying, fadeDurationMs > 0 else {
        try load(path: path)
        if let positionMs, positionMs > 0 {
          try seek(positionMs: positionMs)
        }
        try play(fadeDurationMs: fadeDurationMs, targetVolume: latestVolume)
        return
      }

      let incomingKind = activeSlotKind.opposite
      let incomingSlot = slot(for: incomingKind)
      if let oldURL = incomingSlot.url {
        fileAccess.releaseAccess(for: oldURL)
      }
      incomingSlot.clear()

      let normalizedPath = normalizedFilePath(path)
      let url = try fileAccess.acquireAccess(for: normalizedPath)
      try incomingSlot.load(url: url)

      if let positionMs, positionMs > 0 {
        try incomingSlot.seek(positionMs: positionMs)
      }

      outgoingSlot.gain = 1.0
      incomingSlot.gain = 0.0
      outgoingSlot.applyBaseVolume(latestVolume)
      incomingSlot.applyBaseVolume(latestVolume)

      try incomingSlot.play()
      incomingSlot.gain = 0.0
      incomingSlot.applyBaseVolume(latestVolume)

      startCrossfadeTimer(
        outgoingKind: activeSlotKind,
        incomingKind: incomingKind,
        durationMs: fadeDurationMs
      )
    }
  }

  func play(fadeDurationMs: Int, targetVolume: Double?) throws {
    try syncOnStateQueue {
      guard let slot = publicSlot(), slot.isLoaded else {
        throw engineError("audio is not loaded")
      }

      let target = (targetVolume ?? latestVolume).clamped(to: 0.0...1.0)
      latestVolume = target
      slot.gain = 1.0
      slot.applyBaseVolume(target)

      if fadeDurationMs > 0 {
        slot.gain = 0.0
        slot.applyBaseVolume(target)
        try slot.play()
        startVolumeFade(
          slot: slot,
          from: 0.0,
          to: target,
          durationMs: fadeDurationMs
        )
      } else {
        try slot.play()
        slot.applyBaseVolume(target)
      }
      refreshFftCapture(for: activeSlotKind)
    }
  }

  func pause(fadeDurationMs: Int) throws {
    syncOnStateQueue {
      guard let slot = publicSlot(), slot.isLoaded, slot.isPlaying else { return }
      if fadeDurationMs > 0 {
        let originalVolume = slot.currentVolume
        startVolumeFade(
          slot: slot,
          from: originalVolume,
          to: 0.0,
          durationMs: fadeDurationMs,
          completion: { [weak self] in
            guard let self else { return }
            slot.pause()
            slot.gain = 1.0
            slot.applyBaseVolume(self.latestVolume)
            self.emitPlayerState(playbackState: "PAUSED")
          }
        )
      } else {
        slot.pause()
        slot.gain = 1.0
        slot.applyBaseVolume(latestVolume)
        emitPlayerState(playbackState: "PAUSED")
      }
    }
  }

  func seek(positionMs: Int) throws {
    try syncOnStateQueue {
      guard publicSlot()?.isLoaded == true else {
        throw engineError("audio is not loaded")
      }

      if seekDebounceTimer != nil {
        pendingSeekPositionMs = positionMs
        return
      }

      try executeSeek(positionMs: positionMs)
      startSeekDebounceTimer()
    }
  }

  func setVolume(_ volume: Double) throws {
    syncOnStateQueue {
      latestVolume = volume.clamped(to: 0.0...1.0)
      if primarySlot.isLoaded {
        primarySlot.applyBaseVolume(latestVolume)
      }
      if secondarySlot.isLoaded {
        secondarySlot.applyBaseVolume(latestVolume)
      }
    }
  }

  func getDurationMs() -> Int {
    return syncOnStateQueue {
      publicSlot()?.durationMs ?? 0
    }
  }

  func getCurrentPositionMs() -> Int {
    return syncOnStateQueue {
      publicSlot()?.currentPositionMs ?? 0
    }
  }

  func statusPayload(playbackState: String? = nil, error: String? = nil) -> [String: Any] {
    return syncOnStateQueue {
      let slot = publicSlot()
      var payload: [String: Any] = [
        "playerId": "main",
        "state": playbackState ?? currentPlaybackState(),
        "position": slot?.currentPositionMs ?? 0,
        "duration": slot?.durationMs ?? 0,
        "isPlaying": slot?.isPlaying ?? false,
        "volume": latestVolume,
        "updateTime": Int(Date().timeIntervalSince1970 * 1000),
        "error": error ?? NSNull(),
      ]
      if let path = slot?.url?.path {
        payload["path"] = path
      }
      return payload
    }
  }

  func getEqualizerConfig() -> AppleEqualizerConfig {
    syncOnStateQueue {
      latestEqualizerConfig
    }
  }

  func setEqualizerConfig(_ config: AppleEqualizerConfig) {
    syncOnStateQueue {
      latestEqualizerConfig = AppleEqualizerCodec.sanitized(config)
      applyEqualizerConfig(latestEqualizerConfig)
    }
  }

  func updateFftGroupingOptions(
    frequencyGroups: Int,
    skipHighFrequencyGroups: Int,
    aggregationMode: String
  ) {
    syncOnStateQueue {
      fftGroupingConfig.frequencyGroups = max(1, min(frequencyGroups, fftBinCount))
      fftGroupingConfig.skipHighFrequencyGroups = max(0, skipHighFrequencyGroups)
      fftGroupingConfig.aggregationMode = aggregationMode
    }
  }

  func getLatestFft() throws -> [Double] {
    return syncOnStateQueue {
      consumeLatestFftSnapshot()
    }
  }

  func getWaveform(path: String, expectedChunks: Int) throws -> [Double] {
    guard expectedChunks > 0 else { return [] }
    let normalizedPath = normalizedFilePath(path)
    return try fileAccess.withTemporaryAccess(for: normalizedPath) { url in
      try decodeWaveform(url: url, expectedChunks: expectedChunks)
    }
  }

  func extractFingerprint(path: String, expectedChunks: Int) throws -> String? {
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

  func prepareForFileWrite(path: String? = nil) throws {
    try syncOnStateQueue {
      if let path {
        let normalizedPath = normalizedFilePath(path)
        if isPreparedAccessPath(normalizedPath) {
          return
        }
        if publicSlot()?.url?.path != normalizedPath {
          _ = try fileAccess.acquireAccess(for: normalizedPath)
          insertPreparedAccessPath(normalizedPath)
          return
        }
      }

      guard let slot = publicSlot(), let path = slot.url?.path else { return }
      if isPreparedAccessPath(path) {
        return
      }

      pendingEdit = PendingEdit(
        path: path,
        positionMs: slot.currentPositionMs,
        wasPlaying: slot.isPlaying,
        volume: latestVolume
      )
      stopSlots(releasingFile: true, preservePosition: true)
      _ = try fileAccess.acquireAccess(for: path)
      insertPreparedAccessPath(path)
    }
  }

  func prepareForFileWrite(paths: [String]) throws {
    for path in Self.normalizedUniquePaths(paths) {
      try prepareForFileWrite(path: path)
    }
  }

  func finishFileWrite(path: String? = nil) throws {
    try syncOnStateQueue {
      if let path {
        let normalizedPath = normalizedFilePath(path)
        if publicSlot()?.url?.path != normalizedPath {
          fileAccess.releaseAccess(for: normalizedPath)
          removePreparedAccessPath(normalizedPath)
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
      removePreparedAccessPath(pendingEdit.path)
    }
  }

  func finishFileWrite(paths: [String]) throws {
    for path in Self.normalizedUniquePaths(paths) {
      try finishFileWrite(path: path)
    }
  }

  @discardableResult
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
    syncOnStateQueue {
      cancelTimers()
      pendingEdit = nil
      clearPreparedAccessPaths()
      stopSlots(releasingFile: true, preservePosition: false)
      removeFftCaptureTap()
      fileAccess.releaseAllAccess()
    }
  }

  func currentTimestampMs() -> Double {
    CFAbsoluteTimeGetCurrent() * 1000.0
  }

  func ensureCurrentAccessIsReleased() {
    if let path = publicSlot()?.url {
      fileAccess.releaseAccess(for: path)
    }
  }

  func currentPlaybackState() -> String {
    guard let slot = publicSlot() else {
      return "IDLE"
    }
    if slot.isPlaying {
      return "PLAYING"
    }
    if slot.durationMs > 0, slot.currentPositionMs >= slot.durationMs {
      return "ENDED"
    }
    if slot.currentPositionMs > 0 || slot.isPaused {
      return "PAUSED"
    }
    return "READY"
  }

  func emitPlayerState(playbackState: String? = nil, error: String? = nil) {
    onPlayerStateChanged?(playbackState, error)
  }

  private func installDelegates() {
    primarySlot.player.delegate = self
    secondarySlot.player.delegate = self
  }

  private func syncOnStateQueue<T>(_ work: () throws -> T) rethrows -> T {
    if DispatchQueue.getSpecific(key: stateQueueKey) != nil {
      return try work()
    }
    return try stateQueue.sync(execute: work)
  }

  private var activeSlot: PlaybackSlot {
    slot(for: activeSlotKind)
  }

  private func publicSlot() -> PlaybackSlot? {
    if activeSlot.isLoaded {
      return activeSlot
    }
    if primarySlot.isLoaded {
      return primarySlot
    }
    if secondarySlot.isLoaded {
      return secondarySlot
    }
    return nil
  }

  private func slot(for kind: SlotKind) -> PlaybackSlot {
    switch kind {
    case .primary:
      return primarySlot
    case .secondary:
      return secondarySlot
    }
  }

  private func stopSlots(releasingFile: Bool, preservePosition: Bool) {
    if preservePosition {
      if let slot = publicSlot() {
        slot.storedPositionMs = slot.currentPositionMs
      }
    }

    let slots = [primarySlot, secondarySlot]
    for slot in slots {
      if releasingFile, let url = slot.url {
        fileAccess.releaseAccess(for: url)
      }
      slot.stop()
      if releasingFile {
        slot.clear()
      } else {
        slot.gain = 1.0
        slot.applyBaseVolume(latestVolume)
      }
    }
    if releasingFile {
      removeFftCaptureTap()
    }
  }

  private func executeSeek(positionMs: Int) throws {
    guard let slot = publicSlot(), slot.isLoaded else {
      throw engineError("audio is not loaded")
    }

    let clampedPositionMs = max(0, positionMs)
    let wasPlaying = slot.isPlaying
    try slot.seek(positionMs: clampedPositionMs)
    if !wasPlaying {
      slot.storedPositionMs = clampedPositionMs
    }
    emitPlayerState()
  }

  private func startSeekDebounceTimer() {
    seekDebounceTimer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: stateQueue)
    timer.schedule(deadline: .now() + .milliseconds(200))
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      self.seekDebounceTimer = nil
      guard let pending = self.pendingSeekPositionMs else { return }
      self.pendingSeekPositionMs = nil
      do {
        try self.executeSeek(positionMs: pending)
        self.startSeekDebounceTimer()
      } catch {
        self.emitPlayerState(error: error.localizedDescription)
      }
    }
    seekDebounceTimer = timer
    timer.resume()
  }

  private func startCrossfadeTimer(
    outgoingKind: SlotKind,
    incomingKind: SlotKind,
    durationMs: Int
  ) {
    cancelFadeTimer()
    fadeGeneration &+= 1
    let generation = fadeGeneration
    let outgoingSlot = slot(for: outgoingKind)
    let incomingSlot = slot(for: incomingKind)
    let steps = max(1, durationMs / 16)
    let stepDuration = Double(durationMs) / Double(steps) / 1000.0
    var step = 0

    let timer = DispatchSource.makeTimerSource(queue: stateQueue)
    timer.schedule(deadline: .now(), repeating: stepDuration)
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      guard self.fadeGeneration == generation else {
        self.cancelFadeTimer()
        return
      }

      step += 1
      let progress = min(1.0, Double(step) / Double(steps))
      let outgoingGain = 1.0 - progress
      let incomingGain = progress

      outgoingSlot.gain = outgoingGain
      incomingSlot.gain = incomingGain
      outgoingSlot.applyBaseVolume(self.latestVolume)
      incomingSlot.applyBaseVolume(self.latestVolume)

      if progress >= 1.0 {
        self.cancelFadeTimer()
        self.settleCrossfade(outgoingKind: outgoingKind, incomingKind: incomingKind)
      }
    }
    fadeTimer = timer
    timer.resume()
  }

  private func startVolumeFade(
    slot: PlaybackSlot,
    from: Double,
    to: Double,
    durationMs: Int,
    completion: (() -> Void)? = nil
  ) {
    cancelFadeTimer()
    fadeGeneration &+= 1
    let generation = fadeGeneration
    let steps = max(1, durationMs / 16)
    let stepDuration = Double(durationMs) / Double(steps) / 1000.0
    var step = 0

    let timer = DispatchSource.makeTimerSource(queue: stateQueue)
    timer.schedule(deadline: .now(), repeating: stepDuration)
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      guard self.fadeGeneration == generation else {
        self.cancelFadeTimer()
        return
      }

      step += 1
      let progress = min(1.0, Double(step) / Double(steps))
      let nextVolume = from + ((to - from) * progress)
      slot.gain = 1.0
      slot.applyVolume(nextVolume)

      if progress >= 1.0 {
        self.cancelFadeTimer()
        completion?()
      }
    }
    fadeTimer = timer
    timer.resume()
  }

  private func settleCrossfade(outgoingKind: SlotKind, incomingKind: SlotKind) {
    let outgoingSlot = slot(for: outgoingKind)
    let incomingSlot = slot(for: incomingKind)
    if let oldURL = outgoingSlot.url {
      fileAccess.releaseAccess(for: oldURL)
    }
    outgoingSlot.stop()
    outgoingSlot.clear()
    incomingSlot.gain = 1.0
    incomingSlot.applyBaseVolume(latestVolume)
    activeSlotKind = incomingKind
    refreshFftCapture(for: incomingKind)
    emitPlayerState(playbackState: "PLAYING")
  }

  private func cancelTimers() {
    cancelSeekTimer()
    cancelFadeTimer()
  }

  private func cancelSeekTimer() {
    seekDebounceTimer?.cancel()
    seekDebounceTimer = nil
    pendingSeekPositionMs = nil
  }

  private func cancelFadeTimer() {
    fadeTimer?.cancel()
    fadeTimer = nil
  }

  private func releaseAllAccess() {
    preparedAccessPathsLock.lock()
    let preparedPaths = Array(preparedAccessPaths)
    preparedAccessPaths.removeAll()
    preparedAccessPathsLock.unlock()

    for path in preparedPaths {
      fileAccess.releaseAccess(for: path)
    }
    if let path = primarySlot.url?.path {
      fileAccess.releaseAccess(for: path)
    }
    if let path = secondarySlot.url?.path {
      fileAccess.releaseAccess(for: path)
    }
  }

  private func isPreparedAccessPath(_ path: String) -> Bool {
    preparedAccessPathsLock.lock()
    defer { preparedAccessPathsLock.unlock() }
    return preparedAccessPaths.contains(path)
  }

  private func insertPreparedAccessPath(_ path: String) {
    preparedAccessPathsLock.lock()
    preparedAccessPaths.insert(path)
    preparedAccessPathsLock.unlock()
  }

  private func removePreparedAccessPath(_ path: String) {
    preparedAccessPathsLock.lock()
    preparedAccessPaths.remove(path)
    preparedAccessPathsLock.unlock()
  }

  private func clearPreparedAccessPaths() {
    preparedAccessPathsLock.lock()
    preparedAccessPaths.removeAll()
    preparedAccessPathsLock.unlock()
  }

  private func applyEqualizerConfig(_ config: AppleEqualizerConfig) {
    // The engine keeps the public equalizer configuration for compatibility.
    // The SFBAudioEngine path currently focuses on playback and crossfade.
    latestEqualizerConfig = config
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

  private func engineError(_ message: String) -> NSError {
    NSError(
      domain: "AudioCore",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: message]
    )
  }
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

    vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

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
  private func refreshFftCapture(for slotKind: SlotKind) {
    guard let slot = slotIfLoaded(slotKind) else {
      removeFftCaptureTap()
      return
    }

    if fftTapSlotKind == slotKind, isFftTapInstalled {
      return
    }

    removeFftCaptureTap()
    installFftCaptureTap(for: slotKind, on: slot)
  }

  private func installFftCaptureTap(for slotKind: SlotKind, on slot: PlaybackSlot) {
#if canImport(SFBAudioEngine)
    slot.player.modifyProcessingGraph { engine in
      engine.mainMixerNode.installTap(
        onBus: 0,
        bufferSize: AVAudioFrameCount(self.fftSize / 2),
        format: nil
      ) { [weak self] buffer, _ in
        self?.handleFftTapBuffer(buffer, slotKind: slotKind)
      }
    }
    fftTapSlotKind = slotKind
    isFftTapInstalled = true
    resetFftCaptureState()
#else
    _ = slot
    _ = slotKind
#endif
  }

  private func removeFftCaptureTap() {
#if canImport(SFBAudioEngine)
    primarySlot.player.mainMixerNode.removeTap(onBus: 0)
    secondarySlot.player.mainMixerNode.removeTap(onBus: 0)
#endif
    fftTapSlotKind = nil
    isFftTapInstalled = false
    resetFftCaptureState()
  }

  private func resetFftCaptureState() {
    fftCaptureBuffer.clear()
    fftResultLock.lock()
    fftProcessingGeneration &+= 1
    latestRawFft = Array(repeating: 0.0, count: fftBinCount)
    latestRawTapMagnitudes = Array(repeating: 0.0, count: fftBinCount)
    fftAnalysisRemainder.removeAll(keepingCapacity: true)
    pendingFftFrames.removeAll(keepingCapacity: true)
    fftLastFetchAtMs = nil
    fftResultLock.unlock()
    fftTapCount = 0
    fftLastTapAtMs = nil
  }

  private func slotIfLoaded(_ kind: SlotKind) -> PlaybackSlot? {
    let slot = slot(for: kind)
    return slot.isLoaded ? slot : nil
  }

  private func handleFftTapBuffer(_ buffer: AVAudioPCMBuffer, slotKind: SlotKind) {
    guard fftTapSlotKind == slotKind else { return }
    guard let slot = slotIfLoaded(slotKind), slot.isPlaying else { return }

    fftCaptureBuffer.pushMono(from: buffer)
    let generation = currentFftProcessingGeneration()
    let frameLength = Int(buffer.frameLength)

    fftProcessingQueue.async { [weak self] in
      self?.processFftRingBuffer(frameLength: frameLength, generation: generation)
    }
  }

  private func processFftRingBuffer(frameLength: Int, generation: UInt64) {
    guard isCurrentFftProcessingGeneration(generation) else { return }

    let monoSamples = fftCaptureBuffer.pullAll()
    guard !monoSamples.isEmpty else { return }

    enqueueTapFftFrames(monoSamples, frameLength: frameLength, generation: generation)
  }

  private func enqueueTapFftFrames(
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

  private func currentFftProcessingGeneration() -> UInt64 {
    fftResultLock.lock()
    let generation = fftProcessingGeneration
    fftResultLock.unlock()
    return generation
  }

  private func isCurrentFftProcessingGeneration(_ generation: UInt64) -> Bool {
    fftResultLock.lock()
    let isCurrent = fftProcessingGeneration == generation
    fftResultLock.unlock()
    return isCurrent
  }

  private func consumeLatestFftSnapshot() -> [Double] {
    let now = currentTimestampMs()
    let sampleRate = playbackSampleRate()
    let frameDurationMs = (Double(fftHopSize) / sampleRate) * 1000.0

    if let lastFetch = fftLastFetchAtMs, now - lastFetch < 500 {
      let elapsed = now - lastFetch
      let framesToConsume = Int(elapsed / frameDurationMs)

      if framesToConsume > 0 {
        let toRemove = min(framesToConsume, pendingFftFrames.count)
        if toRemove > 0 {
          latestRawFft = pendingFftFrames[toRemove - 1]
          pendingFftFrames.removeFirst(toRemove)
        }
        fftLastFetchAtMs = lastFetch + (Double(framesToConsume) * frameDurationMs)
      }
    } else {
      if !pendingFftFrames.isEmpty {
        latestRawFft = pendingFftFrames.removeFirst()
      }
      fftLastFetchAtMs = now
    }

    return latestRawFft
  }

  private func playbackSampleRate() -> Double {
    syncOnStateQueue {
      publicSlot()?.sampleRate ?? 44_100
    }
  }

  private func rawZeroFrame() -> [Double] {
    Array(repeating: 0.0, count: fftBinCount)
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

  private func computeMagnitudes(from samples: [Float]) -> [Double] {
    let count = min(samples.count, fftSize)
    guard count > 0, let fftSetup else {
      return rawZeroFrame()
    }

    if count < fftSize {
      fftWorkspace.windowed.withUnsafeMutableBufferPointer { ptr in
        ptr.initialize(repeating: 0)
      }
    }

    samples.withUnsafeBufferPointer { sampleBuffer in
      fftWorkspace.windowed.withUnsafeMutableBufferPointer { windowedBuffer in
        vDSP_vmul(
          sampleBuffer.baseAddress!,
          1,
          fftWorkspace.window,
          1,
          windowedBuffer.baseAddress!,
          1,
          vDSP_Length(count)
        )
      }
    }

    var magnitudes = Array(repeating: 0.0, count: fftBinCount)
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

        vDSP_fft_zrip(fftSetup, &splitComplex, 1, fftLog2Size, FFTDirection(FFT_FORWARD))

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

  private func decodeWaveform(url: URL, expectedChunks: Int) throws -> [Double] {
    let decoder = try AudioDecoder(url: url, detectContentType: true)
    defer { _ = try? decoder.close() }

    _ = try decoder.open()

    let bufferCapacity: AVAudioFrameCount = 4096
    guard let buffer = AVAudioPCMBuffer(
      pcmFormat: decoder.processingFormat,
      frameCapacity: bufferCapacity
    ) else {
      return Array(repeating: 0.0, count: expectedChunks)
    }

    var monoSamples: [Double] = []
    while true {
      try decoder.decode(into: buffer, length: bufferCapacity)
      let frameLength = Int(buffer.frameLength)
      guard frameLength > 0, let channelData = buffer.floatChannelData else {
        break
      }

      let channelCount = max(Int(buffer.format.channelCount), 1)
      for frame in 0..<frameLength {
        var sum = 0.0
        for channel in 0..<channelCount {
          sum += Double(channelData[channel][frame])
        }
        monoSamples.append(sum / Double(channelCount))
      }
    }

    return processWaveform(samples: monoSamples, expectedChunks: expectedChunks)
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
    (value * waveformPrecisionScale).rounded() / waveformPrecisionScale
  }
}

extension AppleAudioEngine: AudioPlayer.Delegate {
  func audioPlayer(_ audioPlayer: AudioPlayer, playbackStateChanged playbackState: AudioPlayer.PlaybackState) {
    syncOnStateQueue {
      let state: String
      switch playbackState {
      case .playing:
        state = "PLAYING"
      case .paused:
        state = "PAUSED"
      case .stopped:
        state = currentPlaybackState()
      @unknown default:
        state = currentPlaybackState()
      }
      emitPlayerState(playbackState: state)
    }
  }

  func audioPlayerEndOfAudio(_ audioPlayer: AudioPlayer) {
    syncOnStateQueue {
      if let slot = slot(matching: audioPlayer) {
        slot.storedPositionMs = slot.durationMs
      }
      emitPlayerState(playbackState: "ENDED")
    }
  }

  func audioPlayer(_ audioPlayer: AudioPlayer, encounteredError error: Error) {
    syncOnStateQueue {
      emitPlayerState(error: error.localizedDescription)
    }
  }

  private func slot(matching player: AudioPlayer) -> PlaybackSlot? {
    if primarySlot.player === player {
      return primarySlot
    }
    if secondarySlot.player === player {
      return secondarySlot
    }
    return nil
  }
}

struct AppleEqualizerConfig {
  let enabled: Bool
  let bandCount: Int
  let preampDb: Double
  let bassBoostDb: Double
  let bassBoostFrequencyHz: Double
  let bassBoostQ: Double
  let bandGainsDb: [Double]
}

enum AppleEqualizerDefaults {
  static let maxBands = 20
  static let minCenterFrequencyHz = 32.0
  static let maxCenterFrequencyHz = 16_000.0
  static let defaultBassBoostFrequencyHz = 80.0
  static let defaultBassBoostQ = 0.75
  static let eqBandQ = 1.0
  static let epsilonGainDb = 0.001
}

enum AppleEqualizerCodec {
  static func readConfig(_ arguments: Any?) -> AppleEqualizerConfig? {
    guard let map = arguments as? [String: Any] else { return nil }

    let enabled = (map["enabled"] as? Bool) ?? false
    let bandCount = readInt(map, key: "bandCount") ?? 0
    let preampDb = readDouble(map, key: "preampDb") ?? 0.0
    let bassBoostDb = readDouble(map, key: "bassBoostDb") ?? 0.0
    let bassBoostFrequencyHz =
      readDouble(map, key: "bassBoostFrequencyHz")
      ?? AppleEqualizerDefaults.defaultBassBoostFrequencyHz
    let bassBoostQ = readDouble(map, key: "bassBoostQ") ?? AppleEqualizerDefaults.defaultBassBoostQ

    let rawBands = map["bandGainsDb"] as? [Any] ?? []
    var bandGainsDb = Array(repeating: 0.0, count: AppleEqualizerDefaults.maxBands)
    for index in 0..<min(rawBands.count, bandGainsDb.count) {
      if let value = rawBands[index] as? Double {
        bandGainsDb[index] = value
      } else if let value = rawBands[index] as? Int {
        bandGainsDb[index] = Double(value)
      } else if let value = rawBands[index] as? Int64 {
        bandGainsDb[index] = Double(value)
      } else if let value = rawBands[index] as? NSNumber {
        bandGainsDb[index] = value.doubleValue
      }
    }

    return sanitized(
      AppleEqualizerConfig(
        enabled: enabled,
        bandCount: bandCount,
        preampDb: preampDb,
        bassBoostDb: bassBoostDb,
        bassBoostFrequencyHz: bassBoostFrequencyHz,
        bassBoostQ: bassBoostQ,
        bandGainsDb: bandGainsDb
      )
    )
  }

  static func sanitized(_ config: AppleEqualizerConfig) -> AppleEqualizerConfig {
    var gains = Array(repeating: 0.0, count: AppleEqualizerDefaults.maxBands)
    for index in 0..<min(config.bandGainsDb.count, gains.count) {
      gains[index] = config.bandGainsDb[index]
    }

    return AppleEqualizerConfig(
      enabled: config.enabled,
      bandCount: max(0, min(config.bandCount, AppleEqualizerDefaults.maxBands)),
      preampDb: config.preampDb,
      bassBoostDb: config.bassBoostDb,
      bassBoostFrequencyHz: config.bassBoostFrequencyHz.clamped(to: 20.0...240.0),
      bassBoostQ: config.bassBoostQ.clamped(to: 0.1...2.0),
      bandGainsDb: gains
    )
  }

  static func payload(_ config: AppleEqualizerConfig) -> [String: Any] {
    [
      "enabled": config.enabled,
      "bandCount": config.bandCount,
      "preampDb": config.preampDb,
      "bassBoostDb": config.bassBoostDb,
      "bassBoostFrequencyHz": config.bassBoostFrequencyHz,
      "bassBoostQ": config.bassBoostQ,
      "bandGainsDb": config.bandGainsDb,
    ]
  }

  static func defaultConfig() -> AppleEqualizerConfig {
    AppleEqualizerConfig(
      enabled: false,
      bandCount: AppleEqualizerDefaults.maxBands,
      preampDb: 0.0,
      bassBoostDb: 0.0,
      bassBoostFrequencyHz: AppleEqualizerDefaults.defaultBassBoostFrequencyHz,
      bassBoostQ: AppleEqualizerDefaults.defaultBassBoostQ,
      bandGainsDb: Array(repeating: 0.0, count: AppleEqualizerDefaults.maxBands)
    )
  }

  private static func readInt(_ map: [String: Any], key: String) -> Int? {
    if let value = map[key] as? Int { return value }
    if let value = map[key] as? Int64 { return Int(value) }
    if let value = map[key] as? Double { return Int(value) }
    if let value = map[key] as? NSNumber { return value.intValue }
    return nil
  }

  private static func readDouble(_ map: [String: Any], key: String) -> Double? {
    if let value = map[key] as? Double { return value }
    if let value = map[key] as? Int { return Double(value) }
    if let value = map[key] as? Int64 { return Double(value) }
    if let value = map[key] as? NSNumber { return value.doubleValue }
    return nil
  }
}

struct AppleFftGroupingConfig {
  var frequencyGroups: Int = 32
  var skipHighFrequencyGroups: Int = 0
  var aggregationMode: String = "peak"
}

extension Comparable {
  func clamped(to limits: ClosedRange<Self>) -> Self {
    min(max(self, limits.lowerBound), limits.upperBound)
  }
}
