import AVFoundation
import Foundation

#if os(macOS)
import FlutterMacOS
#else
import Flutter
#endif

private struct AppleEqualizerConfig {
  let enabled: Bool
  let bandCount: Int
  let preampDb: Double
  let bassBoostDb: Double
  let bassBoostFrequencyHz: Double
  let bassBoostQ: Double
  let bandGainsDb: [Double]
}

public final class AudioCorePlugin: NSObject, FlutterPlugin {
  private let fileAccess = SecurityScopedFileAccessCoordinator()
  private let engine: AppleAudioEngine
  private var channel: FlutterMethodChannel?
  private var notificationTokens: [NSObjectProtocol] = []

#if os(iOS)
  private let audioSession = AVAudioSession.sharedInstance()
  private var shouldResumeAfterInterruption = false
#endif

  public override init() {
    self.engine = AppleAudioEngine(fileAccess: fileAccess)
    super.init()
    #if os(iOS)
    configureAudioSession()
    registerAudioSessionObservers()
    #endif
  }

  deinit {
    let center = NotificationCenter.default
    notificationTokens.forEach { center.removeObserver($0) }
    notificationTokens.removeAll()
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "my_exoplayer",
      binaryMessenger: registrar.messenger()
    )
    let instance = AudioCorePlugin()
    instance.channel = channel
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "sayHello":
      #if os(iOS)
      configureAudioSession()
      #endif
      engine.ensureReady()
      sendPlayerState()
      result(nil)
    case "load":
      guard let args = call.arguments as? [String: Any],
            let path = args["url"] as? String else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "URL is null", details: nil))
        return
      }
      do {
        try engine.load(path: path)
        sendPlayerState()
        result(nil)
      } catch {
        result(FlutterError(code: "LOAD_FAILED", message: error.localizedDescription, details: nil))
      }
    case "crossfade":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "Path is null", details: nil))
        return
      }
      let durationMs = Self.readInt(call.arguments, key: "durationMs") ?? 0
      do {
        #if os(iOS)
        try activateAudioSession()
        #endif
        try engine.crossfade(path: path, durationMs: durationMs)
        sendPlayerState()
        result(nil)
      } catch {
        result(FlutterError(code: "CROSSFADE_FAILED", message: error.localizedDescription, details: nil))
      }
    case "play":
      let fadeDurationMs = Self.readInt(call.arguments, key: "fadeDurationMs") ?? 0
      let targetVolume = Self.readDouble(call.arguments, key: "targetVolume")
      do {
        #if os(iOS)
        try activateAudioSession()
        #endif
        try engine.play(fadeDurationMs: fadeDurationMs, targetVolume: targetVolume)
        sendPlayerState()
        result(nil)
      } catch {
        result(FlutterError(code: "PLAY_FAILED", message: error.localizedDescription, details: nil))
      }
    case "pause":
      let fadeDurationMs = Self.readInt(call.arguments, key: "fadeDurationMs") ?? 0
      do {
        try engine.pause(fadeDurationMs: fadeDurationMs)
        sendPlayerState()
        result(nil)
      } catch {
        result(FlutterError(code: "PAUSE_FAILED", message: error.localizedDescription, details: nil))
      }
    case "seek":
      let positionMs = Self.readInt(call.arguments, key: "position") ?? 0
      do {
        try engine.seek(positionMs: positionMs)
        sendPlayerState()
        result(nil)
      } catch {
        result(FlutterError(code: "SEEK_FAILED", message: error.localizedDescription, details: nil))
      }
    case "setVolume":
      let volume = Self.readDouble(call.arguments, key: "volume") ?? 1.0
      do {
        try engine.setVolume(volume)
        sendPlayerState()
        result(nil)
      } catch {
        result(FlutterError(code: "VOLUME_FAILED", message: error.localizedDescription, details: nil))
      }
    case "setEqualizerConfig":
      guard let config = Self.readEqualizerConfig(call.arguments) else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "Equalizer config is invalid", details: nil))
        return
      }
      engine.setEqualizerConfig(config)
      result(nil)
    case "getEqualizerConfig":
      result(Self.equalizerConfigPayload(engine.getEqualizerConfig()))
    case "getDuration":
      result(engine.getDurationMs())
    case "getCurrentPosition":
      result(engine.getCurrentPositionMs())
    case "getLatestFft":
      do {
        result(engine.getLatestFft())
      } catch {
        result(FlutterError(code: "FFT_FAILED", message: error.localizedDescription, details: nil))
      }
    case "getAudioPcm":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "Path is null", details: nil))
        return
      }
      let sampleStride = (args["sampleStride"] as? Int) ?? 0
      do {
        result(try engine.getAudioPcm(path: path, sampleStride: sampleStride))
      } catch {
        result(FlutterError(code: "PCM_FAILED", message: error.localizedDescription, details: nil))
      }
    case "getAudioPcmChannelCount":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "Path is null", details: nil))
        return
      }
      do {
        result(try engine.getAudioPcmChannelCount(path: path))
      } catch {
        result(FlutterError(code: "PCM_FAILED", message: error.localizedDescription, details: nil))
      }
    case "getFingerprintPcm":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "Path is null", details: nil))
        return
      }
      let maxDurationMs = Self.readInt(call.arguments, key: "maxDurationMs") ?? 20_000
      do {
        result(try engine.getFingerprintPcm(path: path, maxDurationMs: maxDurationMs))
      } catch {
        result(FlutterError(code: "PCM_FAILED", message: error.localizedDescription, details: nil))
      }
    case "prepareForFileWrite":
      let path = Self.readString(call.arguments, key: "path")
      do {
        try engine.prepareForFileWrite(path: path)
        sendPlayerState()
        result(nil)
      } catch {
        result(FlutterError(code: "PREPARE_FAILED", message: error.localizedDescription, details: nil))
      }
    case "finishFileWrite":
      let path = Self.readString(call.arguments, key: "path")
      do {
        try engine.finishFileWrite(path: path)
        sendPlayerState()
        result(nil)
      } catch {
        result(FlutterError(code: "FINISH_FAILED", message: error.localizedDescription, details: nil))
      }
    case "registerPersistentAccess":
      guard let path = Self.readString(call.arguments, key: "path") else {
        result(false)
        return
      }
      result(engine.registerPersistentAccess(path: path))
    case "forgetPersistentAccess":
      guard let path = Self.readString(call.arguments, key: "path") else {
        result(nil)
        return
      }
      engine.forgetPersistentAccess(path: path)
      result(nil)
    case "hasPersistentAccess":
      guard let path = Self.readString(call.arguments, key: "path") else {
        result(false)
        return
      }
      result(engine.hasPersistentAccess(path: path))
    case "listPersistentAccessPaths":
      result(engine.listPersistentAccessPaths())
    case "dispose":
      engine.dispose()
      #if os(iOS)
      deactivateAudioSession()
      shouldResumeAfterInterruption = false
      #endif
      sendPlayerState()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func sendPlayerState() {
    guard let channel else { return }
    DispatchQueue.main.async {
      channel.invokeMethod("onPlayerStateChanged", arguments: self.engine.statusPayload())
    }
  }

  private static func readInt(_ arguments: Any?, key: String) -> Int? {
    guard let map = arguments as? [String: Any] else { return nil }
    if let value = map[key] as? Int { return value }
    if let value = map[key] as? Int64 { return Int(value) }
    if let value = map[key] as? Double { return Int(value) }
    if let value = map[key] as? NSNumber { return value.intValue }
    return nil
  }

  private static func readDouble(_ arguments: Any?, key: String) -> Double? {
    guard let map = arguments as? [String: Any] else { return nil }
    if let value = map[key] as? Double { return value }
    if let value = map[key] as? Int { return Double(value) }
    if let value = map[key] as? Int64 { return Double(value) }
    if let value = map[key] as? NSNumber { return value.doubleValue }
    return nil
  }

  private static func readString(_ arguments: Any?, key: String) -> String? {
    guard let map = arguments as? [String: Any] else { return nil }
    guard let value = map[key] as? String else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func readEqualizerConfig(_ arguments: Any?) -> AppleEqualizerConfig? {
    guard let map = arguments as? [String: Any] else { return nil }
    let bandCountLimit = 20

    let enabled = (map["enabled"] as? Bool) ?? false
    let bandCount = Self.readInt(arguments, key: "bandCount") ?? 0
    let preampDb = Self.readDouble(arguments, key: "preampDb") ?? 0.0
    let bassBoostDb = Self.readDouble(arguments, key: "bassBoostDb") ?? 0.0
    let bassBoostFrequencyHz = Self.readDouble(arguments, key: "bassBoostFrequencyHz") ?? 80.0
    let bassBoostQ = Self.readDouble(arguments, key: "bassBoostQ") ?? 0.75

    let rawBands = map["bandGainsDb"] as? [Any] ?? []
    var bandGainsDb = Array(repeating: 0.0, count: max(0, min(bandCount, bandCountLimit)))
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

    return AppleEqualizerConfig(
      enabled: enabled,
      bandCount: max(0, min(bandCount, bandCountLimit)),
      preampDb: preampDb,
      bassBoostDb: bassBoostDb,
      bassBoostFrequencyHz: bassBoostFrequencyHz,
      bassBoostQ: bassBoostQ,
      bandGainsDb: bandGainsDb
    )
  }

  private static func equalizerConfigPayload(_ config: AppleEqualizerConfig) -> [String: Any] {
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

#if os(iOS)
  private func configureAudioSession() {
    do {
      try audioSession.setCategory(
        .playback,
        mode: .default,
        options: [.allowAirPlay, .allowBluetooth, .allowBluetoothA2DP]
      )
    } catch {
      debugPrint("AudioCorePlugin: failed to configure AVAudioSession: \(error)")
    }
  }

  private func activateAudioSession() throws {
    try audioSession.setCategory(
      .playback,
      mode: .default,
      options: [.allowAirPlay, .allowBluetooth, .allowBluetoothA2DP]
    )
    try audioSession.setActive(true, options: [])
  }

  private func deactivateAudioSession() {
    do {
      try audioSession.setActive(false, options: [.notifyOthersOnDeactivation])
    } catch {
      debugPrint("AudioCorePlugin: failed to deactivate AVAudioSession: \(error)")
    }
  }

  private func registerAudioSessionObservers() {
    let center = NotificationCenter.default
    notificationTokens.append(
      center.addObserver(
        forName: AVAudioSession.interruptionNotification,
        object: audioSession,
        queue: .main
      ) { [weak self] notification in
        self?.handleInterruption(notification)
      }
    )
    notificationTokens.append(
      center.addObserver(
        forName: AVAudioSession.routeChangeNotification,
        object: audioSession,
        queue: .main
      ) { [weak self] notification in
        self?.handleRouteChange(notification)
      }
    )
  }

  private func handleInterruption(_ notification: Notification) {
    guard let userInfo = notification.userInfo,
          let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
          let interruptionType = AVAudioSession.InterruptionType(rawValue: typeValue) else {
      return
    }

    switch interruptionType {
    case .began:
      if engine.isPlaying {
        shouldResumeAfterInterruption = true
        try? engine.pause(fadeDurationMs: 0)
        sendPlayerState()
      } else {
        shouldResumeAfterInterruption = false
      }
    case .ended:
      let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
      let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
      let shouldResume = options.contains(.shouldResume)
      if shouldResumeAfterInterruption && shouldResume {
        do {
          try activateAudioSession()
          try engine.play(fadeDurationMs: 0, targetVolume: nil)
        } catch {
          debugPrint("AudioCorePlugin: failed to resume after interruption: \(error)")
        }
      }
      shouldResumeAfterInterruption = false
      sendPlayerState()
    @unknown default:
      shouldResumeAfterInterruption = false
    }
  }

  private func handleRouteChange(_ notification: Notification) {
    guard let userInfo = notification.userInfo,
          let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
          let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
      return
    }

    guard reason == .oldDeviceUnavailable else { return }

    if engine.isPlaying {
      shouldResumeAfterInterruption = false
      try? engine.pause(fadeDurationMs: 0)
      sendPlayerState()
    }
  }
#endif
}

private final class AppleAudioEngine {
  private struct PendingEdit {
    let path: String
    let positionMs: Int
    let wasPlaying: Bool
    let volume: Double
  }

  private struct EqualizerBandLayout {
    static let bandCount = 20
    static let bassBandIndex = 20
    static let totalBandCount = 21
  }

  private let fftSize = 1024
  private let fftBinCount = 512
  private let fileAccess: SecurityScopedFileAccessCoordinator
  private let engine = AVAudioEngine()
  private let playerNode = AVAudioPlayerNode()
  private let equalizerNode = AVAudioUnitEQ(numberOfBands: EqualizerBandLayout.totalBandCount)
  private var currentURL: URL?
  private var currentFile: AVAudioFile?
  private var sampleRate: Double = 44_100
  private var latestVolume: Double = 1.0
  private var latestEqualizerConfig = AppleAudioEngine.defaultEqualizerConfig()
  private var pendingEdit: PendingEdit?
  private var fadeTimer: Timer?
  private var preparedAccessPaths = Set<String>()
  private var playbackFramePosition: AVAudioFramePosition = 0
  private var isEngineConfigured = false
  private var isPlaybackScheduled = false

  init(fileAccess: SecurityScopedFileAccessCoordinator) {
    self.fileAccess = fileAccess
    configureEngineIfNeeded()
    applyEqualizerConfig(latestEqualizerConfig)
  }

  func ensureReady() {
    // The native engine is lazy; no-op here keeps the channel contract simple.
  }

  var isPlaying: Bool {
    playerNode.isPlaying
  }

  func load(path: String) throws {
    stopPlayback(releasingFile: true, preservePosition: false)
    releaseCurrentAccessIfNeeded()

    let url = try fileAccess.acquireAccess(for: path)
    let file = try AVAudioFile(forReading: url)
    sampleRate = file.processingFormat.sampleRate
    currentURL = url
    currentFile = file
    playbackFramePosition = 0
    isPlaybackScheduled = false
    preparedAccessPaths.remove(url.path)
  }

  func crossfade(path: String, durationMs: Int) throws {
    try load(path: path)
    try play(fadeDurationMs: durationMs, targetVolume: latestVolume)
  }

  func play(fadeDurationMs: Int, targetVolume: Double?) throws {
    guard currentFile != nil else {
      throw NSError(
        domain: "AudioCore",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "audio is not loaded"]
      )
    }

    let target = (targetVolume ?? latestVolume).clamped(to: 0.0...1.0)
    latestVolume = target
    try startPlaybackIfNeeded(from: currentPlaybackFramePosition(), volume: target)

    if fadeDurationMs > 0 {
      playerNode.volume = 0.0
      fadeVolume(from: 0.0, to: target, durationMs: fadeDurationMs) { [weak self] in
        self?.playerNode.volume = Float(target)
      }
    } else {
      playerNode.volume = Float(target)
    }
  }

  func pause(fadeDurationMs: Int) throws {
    guard playerNode.isPlaying else { return }

    if fadeDurationMs > 0 {
      let originalVolume = Double(playerNode.volume)
      fadeVolume(from: originalVolume, to: 0.0, durationMs: fadeDurationMs) { [weak self] in
        guard let self else { return }
        self.playbackFramePosition = self.currentPlaybackFramePosition()
        self.stopPlayback(releasingFile: false, preservePosition: true)
        self.playerNode.volume = Float(self.latestVolume)
      }
    } else {
      playbackFramePosition = currentPlaybackFramePosition()
      stopPlayback(releasingFile: false, preservePosition: true)
    }
  }

  func seek(positionMs: Int) throws {
    guard let currentFile else {
      throw NSError(
        domain: "AudioCore",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "audio is not loaded"]
      )
    }

    let targetFrame = framePosition(forMilliseconds: positionMs, sampleRate: sampleRate)
    let clampedFrame = max(0, min(targetFrame, currentFile.length))
    let wasPlaying = playerNode.isPlaying
    playbackFramePosition = clampedFrame

    if wasPlaying {
      stopPlayback(releasingFile: false, preservePosition: true)
      try startPlaybackIfNeeded(from: clampedFrame, volume: latestVolume)
    }
  }

  func setVolume(_ volume: Double) throws {
    let clamped = volume.clamped(to: 0.0...1.0)
    latestVolume = clamped
    playerNode.volume = Float(clamped)
  }

  func getDurationMs() -> Int {
    guard let currentFile else { return 0 }
    return max(0, frameCountToMilliseconds(currentFile.length, sampleRate: sampleRate))
  }

  func getCurrentPositionMs() -> Int {
    return max(0, framePositionToMilliseconds(currentPlaybackFramePosition(), sampleRate: sampleRate))
  }

  func getLatestFft() throws -> [Double] {
    guard let url = currentURL else {
      return Array(repeating: 0.0, count: fftBinCount)
    }

    let positionMs = getCurrentPositionMs()
    let centerFrame = AVAudioFramePosition((Double(positionMs) / 1000.0) * sampleRate)
    let startFrame = max(0, centerFrame - AVAudioFramePosition(fftSize / 2))
    let monoSamples = try readMonoWindow(
      url: url,
      startFrame: startFrame,
      frameCount: fftSize
    )
    return computeMagnitudes(from: monoSamples)
  }

  func getAudioPcm(path: String, sampleStride: Int) throws -> [Float] {
    return try fileAccess.withTemporaryAccess(for: path) { url in
      try readInterleavedPCM(url: url, sampleStride: sampleStride)
    }
  }

  func getAudioPcmChannelCount(path: String) throws -> Int {
    try fileAccess.withTemporaryAccess(for: path) { url in
      let file = try AVAudioFile(forReading: url)
      return Int(file.processingFormat.channelCount)
    }
  }

  func getFingerprintPcm(path: String, maxDurationMs: Int) throws -> [String: Any] {
    try fileAccess.withTemporaryAccess(for: path) { url in
      let file = try AVAudioFile(forReading: url)
      let format = file.processingFormat
      return [
        "samples": try readInterleavedPCM(
          url: url,
          sampleStride: 0,
          maxDurationMs: maxDurationMs
        ),
        "sampleRate": Int(format.sampleRate.rounded()),
        "channels": Int(format.channelCount),
      ]
    }
  }

  func prepareForFileWrite(path: String? = nil) throws {
    if let path {
      let normalizedPath = normalizedFilePath(path)
      if preparedAccessPaths.contains(normalizedPath) {
        return
      }

      if currentURL?.path != normalizedPath {
        _ = try fileAccess.acquireAccess(for: normalizedPath)
        preparedAccessPaths.insert(normalizedPath)
        return
      }
    }

    guard let path = currentURL?.path else { return }
    if preparedAccessPaths.contains(path) {
      return
    }

    let wasPlaying = playerNode.isPlaying
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

  func finishFileWrite(path: String? = nil) throws {
    if let path {
      let normalizedPath = normalizedFilePath(path)
      if currentURL?.path != normalizedPath {
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

  func dispose() {
    fadeTimer?.invalidate()
    fadeTimer = nil
    pendingEdit = nil
    preparedAccessPaths.removeAll()
    stopPlayback(releasingFile: true, preservePosition: false)
    fileAccess.releaseAllAccess()
    currentURL = nil
    currentFile = nil
  }

  func statusPayload() -> [String: Any] {
    var payload: [String: Any] = [
      "playerId": "main",
      "position": getCurrentPositionMs(),
      "duration": getDurationMs(),
      "isPlaying": playerNode.isPlaying,
      "volume": latestVolume,
    ]
    if let path = currentURL?.path {
      payload["path"] = path
    }
    return payload
  }

  private func normalizedFilePath(_ path: String) -> String {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("file://"), let url = URL(string: trimmed) {
      return url.standardizedFileURL.resolvingSymlinksInPath().path
    }
    return URL(fileURLWithPath: trimmed).standardizedFileURL.resolvingSymlinksInPath().path
  }

  private func configureEngineIfNeeded() {
    guard !isEngineConfigured else { return }
    engine.attach(playerNode)
    engine.attach(equalizerNode)
    engine.connect(playerNode, to: equalizerNode, format: nil)
    engine.connect(equalizerNode, to: engine.mainMixerNode, format: nil)
    engine.prepare()
    isEngineConfigured = true
  }

  private func applyEqualizerConfig(_ config: AppleEqualizerConfig) {
    let availableBandCount = equalizerNode.bands.count
    let userBandCount = min(EqualizerBandLayout.bandCount, max(0, availableBandCount - 1))
    let clampedBandCount = max(0, min(config.bandCount, userBandCount))
    let bandFrequencies = Self.bandCenterFrequencies(count: EqualizerBandLayout.bandCount)

    equalizerNode.globalGain = Float(config.enabled ? config.preampDb : 0.0)

    for index in 0..<userBandCount {
      let band = equalizerNode.bands[index]
      band.bypass = !config.enabled || index >= clampedBandCount
      band.filterType = .parametric
      band.frequency = Float(bandFrequencies[index])
      band.gain = index < config.bandGainsDb.count ? Float(config.bandGainsDb[index]) : 0.0
      band.bandwidth = Self.bandwidth(forQ: config.bassBoostQ)
    }

    if availableBandCount > userBandCount {
      let bassBand = equalizerNode.bands[userBandCount]
      bassBand.bypass = !config.enabled || config.bassBoostDb == 0.0
      bassBand.filterType = .lowShelf
      bassBand.frequency = Float(config.bassBoostFrequencyHz)
      bassBand.gain = Float(config.bassBoostDb)
      bassBand.bandwidth = Self.bandwidth(forQ: config.bassBoostQ)
    }
  }

  private func startPlaybackIfNeeded(from framePosition: AVAudioFramePosition, volume: Double) throws {
    guard let currentFile else {
      throw NSError(
        domain: "AudioCore",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "audio is not loaded"]
      )
    }

    configureEngineIfNeeded()
    applyEqualizerConfig(latestEqualizerConfig)

    if playerNode.isPlaying {
      playerNode.volume = Float(volume)
      return
    }

    let clampedFrame = max(0, min(framePosition, currentFile.length))
    guard clampedFrame < currentFile.length else {
      playbackFramePosition = currentFile.length
      return
    }

    if engine.isRunning == false {
      try engine.start()
    }

    playerNode.stop()
    let framesRemaining = AVAudioFrameCount(currentFile.length - clampedFrame)
    playerNode.scheduleSegment(
      currentFile,
      startingFrame: clampedFrame,
      frameCount: framesRemaining,
      at: nil,
      completionHandler: { [weak self] in
        self?.handlePlaybackCompleted()
      }
    )
    playbackFramePosition = clampedFrame
    isPlaybackScheduled = true
    playerNode.volume = Float(volume)
    playerNode.play()
  }

  private func handlePlaybackCompleted() {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      if let currentFile = self.currentFile {
        self.playbackFramePosition = currentFile.length
      }
      self.isPlaybackScheduled = false
    }
  }

  private func stopPlayback(releasingFile: Bool, preservePosition: Bool) {
    fadeTimer?.invalidate()
    fadeTimer = nil

    if preservePosition {
      playbackFramePosition = currentPlaybackFramePosition()
    }

    playerNode.stop()
    isPlaybackScheduled = false

    if releasingFile {
      currentFile = nil
    }
  }

  private func releaseCurrentAccessIfNeeded() {
    guard let currentURL else { return }
    fileAccess.releaseAccess(for: currentURL)
    self.currentURL = nil
  }

  private func currentPlaybackFramePosition() -> AVAudioFramePosition {
    guard let currentFile else { return playbackFramePosition }
    guard playerNode.isPlaying,
          let nodeTime = playerNode.lastRenderTime,
          let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
      return max(0, min(playbackFramePosition, currentFile.length))
    }

    let renderedFrames = max(0, playerTime.sampleTime)
    return max(0, min(playbackFramePosition + renderedFrames, currentFile.length))
  }

  private func framePosition(forMilliseconds ms: Int, sampleRate: Double) -> AVAudioFramePosition {
    guard sampleRate > 0 else { return 0 }
    let frame = (Double(ms) / 1000.0) * sampleRate
    return AVAudioFramePosition(frame.rounded(.down))
  }

  private func framePositionToMilliseconds(_ frame: AVAudioFramePosition, sampleRate: Double) -> Int {
    guard sampleRate > 0 else { return 0 }
    return max(0, Int(((Double(frame) / sampleRate) * 1000.0).rounded()))
  }

  private func frameCountToMilliseconds(_ frameCount: AVAudioFramePosition, sampleRate: Double) -> Int {
    framePositionToMilliseconds(frameCount, sampleRate: sampleRate)
  }

  private static func bandwidth(forQ q: Double) -> Float {
    let safeQ = max(q, 0.0001)
    let bandwidth = 1.0 / safeQ
    return Float(max(0.1, min(bandwidth, 4.0)))
  }

  private static func bandCenterFrequencies(count: Int) -> [Double] {
    let safeCount = max(count, 1)
    if safeCount == 1 {
      return [1000.0]
    }

    let minFrequency = 32.0
    let maxFrequency = 16_000.0
    let ratio = maxFrequency / minFrequency
    return (0..<safeCount).map { index in
      let exponent = Double(index) / Double(safeCount - 1)
      return minFrequency * pow(ratio, exponent)
    }
  }

  private static func defaultEqualizerConfig() -> AppleEqualizerConfig {
    AppleEqualizerConfig(
      enabled: false,
      bandCount: EqualizerBandLayout.bandCount,
      preampDb: 0.0,
      bassBoostDb: 0.0,
      bassBoostFrequencyHz: 80.0,
      bassBoostQ: 0.75,
      bandGainsDb: Array(repeating: 0.0, count: EqualizerBandLayout.bandCount)
    )
  }

  func setEqualizerConfig(_ config: AppleEqualizerConfig) {
    latestEqualizerConfig = config
    applyEqualizerConfig(config)
  }

  func getEqualizerConfig() -> AppleEqualizerConfig {
    latestEqualizerConfig
  }

  private func readInterleavedPCM(
    url: URL,
    sampleStride: Int,
    maxDurationMs: Int = 0
  ) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    let channels = Int(format.channelCount)
    let stride = max(sampleStride, 1)
    let bufferCapacity: AVAudioFrameCount = 4096
    let maxFrames = maxDurationMs > 0
      ? AVAudioFrameCount(
        min(
          file.length,
          AVAudioFramePosition(
            (format.sampleRate * Double(maxDurationMs) / 1000.0).rounded(.down)
          )
        )
      )
      : file.length
    let endFrame = min(file.length, maxFrames)
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

  private func readMonoWindow(
    url: URL,
    startFrame: AVAudioFramePosition,
    frameCount: Int
  ) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
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

  private func computeMagnitudes(from samples: [Float]) -> [Double] {
    let count = samples.count
    guard count > 0 else {
      return Array(repeating: 0.0, count: fftBinCount)
    }

    var windowed = samples
    let denominator = max(Double(count - 1), 1.0)
    var windowSum = 0.0
    for index in 0..<count {
      let phase = (2.0 * Double.pi * Double(index)) / denominator
      let weight = 0.5 - 0.5 * cos(phase)
      windowed[index] = Float(Double(windowed[index]) * weight)
      windowSum += weight
    }
    let safeWindowSum = max(windowSum, 1e-9)

    var magnitudes = Array(repeating: 0.0, count: fftBinCount)
    let n = Double(count)
    for bin in 0..<fftBinCount {
      let theta = -2.0 * Double.pi * Double(bin) / n
      let cosTheta = cos(theta)
      let sinTheta = sin(theta)
      var wReal = 1.0
      var wImag = 0.0
      var real = 0.0
      var imag = 0.0

      for sample in windowed {
        let value = Double(sample)
        real += value * wReal
        imag += value * wImag

        let nextReal = (wReal * cosTheta) - (wImag * sinTheta)
        let nextImag = (wReal * sinTheta) + (wImag * cosTheta)
        wReal = nextReal
        wImag = nextImag
      }

      let scale = bin == 0 ? 1.0 : 2.0
      magnitudes[bin] = (sqrt((real * real) + (imag * imag)) * scale) / safeWindowSum
    }

    return magnitudes
  }

  private func fadeVolume(
    from: Double,
    to: Double,
    durationMs: Int,
    completion: @escaping () -> Void
  ) {
    fadeTimer?.invalidate()
    let steps = max(1, durationMs / 16)
    var step = 0
    let stepDurationSeconds = Double(durationMs) / Double(steps) / 1000.0
    fadeTimer = Timer.scheduledTimer(
      withTimeInterval: stepDurationSeconds,
      repeats: true
    ) { [weak self] timer in
      guard let self else {
        timer.invalidate()
        return
      }
      step += 1
      let progress = min(1.0, Double(step) / Double(steps))
      let nextVolume = from + ((to - from) * progress)
      self.playerNode.volume = Float(nextVolume.clamped(to: 0.0...1.0))
      if progress >= 1.0 {
        timer.invalidate()
        self.fadeTimer = nil
        completion()
      }
    }
    RunLoop.main.add(fadeTimer!, forMode: .common)
  }
}

private extension Comparable {
  func clamped(to limits: ClosedRange<Self>) -> Self {
    min(max(self, limits.lowerBound), limits.upperBound)
  }
}
