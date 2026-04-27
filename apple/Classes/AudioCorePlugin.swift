import AVFoundation
import Foundation

#if os(macOS)
import FlutterMacOS
#else
import Flutter
#endif

public final class AudioCorePlugin: NSObject, FlutterPlugin {
  private let fileAccess = SecurityScopedFileAccessCoordinator()
  private let engine: AppleAudioEngine
  private var channel: FlutterMethodChannel?

#if os(iOS)
  private let audioSessionManager = AppleAudioSessionManager()
  private var shouldResumeAfterInterruption = false
#endif

  public override init() {
    self.engine = AppleAudioEngine(fileAccess: fileAccess)
    super.init()
    self.engine.onPlayerStateChanged = { [weak self] playbackState, error in
      self?.sendPlayerState(playbackState: playbackState, error: error)
    }

#if os(iOS)
    audioSessionManager.configure()
    registerAudioSessionObservers()
#endif
  }

  deinit {
#if os(iOS)
    audioSessionManager.stopObserving()
    audioSessionManager.deactivate()
#endif
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
#if os(macOS)
    let messenger = registrar.messenger
#else
    let messenger = registrar.messenger()
#endif
    let channel = FlutterMethodChannel(
      name: "audio_core.player",
      binaryMessenger: messenger
    )
    let instance = AudioCorePlugin()
    instance.channel = channel
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "sayHello":
#if os(iOS)
      audioSessionManager.configure()
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
        sendPlayerState(error: error.localizedDescription)
        result(FlutterError(code: "LOAD_FAILED", message: error.localizedDescription, details: nil))
      }

    case "crossfade":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "Path is null", details: nil))
        return
      }
      let durationMs = Self.readInt(call.arguments, key: "durationMs") ?? 0
      let positionMs = Self.readInt(call.arguments, key: "positionMs")
      do {
#if os(iOS)
        try activateAudioSession()
#endif
        try engine.crossfade(path: path, durationMs: durationMs, positionMs: positionMs)
        sendPlayerState()
        result(nil)
      } catch {
        sendPlayerState(error: error.localizedDescription)
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
        sendPlayerState(error: error.localizedDescription)
        result(FlutterError(code: "PLAY_FAILED", message: error.localizedDescription, details: nil))
      }

    case "pause":
      let fadeDurationMs = Self.readInt(call.arguments, key: "fadeDurationMs") ?? 0
      do {
        try engine.pause(fadeDurationMs: fadeDurationMs)
        sendPlayerState()
        result(nil)
      } catch {
        sendPlayerState(error: error.localizedDescription)
        result(FlutterError(code: "PAUSE_FAILED", message: error.localizedDescription, details: nil))
      }

    case "seek":
      let positionMs = Self.readInt(call.arguments, key: "position") ?? 0
      do {
        try engine.seek(positionMs: positionMs)
        sendPlayerState()
        result(nil)
      } catch {
        sendPlayerState(error: error.localizedDescription)
        result(FlutterError(code: "SEEK_FAILED", message: error.localizedDescription, details: nil))
      }

    case "setVolume":
      let volume = Self.readDouble(call.arguments, key: "volume") ?? 1.0
      do {
        try engine.setVolume(volume)
        sendPlayerState()
        result(nil)
      } catch {
        sendPlayerState(error: error.localizedDescription)
        result(FlutterError(code: "VOLUME_FAILED", message: error.localizedDescription, details: nil))
      }

    case "setEqualizerConfig":
      guard let config = AppleEqualizerCodec.readConfig(call.arguments) else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "Equalizer config is invalid", details: nil))
        return
      }
      engine.setEqualizerConfig(config)
      result(nil)

    case "getEqualizerConfig":
      result(AppleEqualizerCodec.payload(engine.getEqualizerConfig()))

    case "getDuration":
      result(engine.getDurationMs())

    case "getCurrentPosition":
      result([
        "position": engine.getCurrentPositionMs(),
        "takenAt": Int(Date().timeIntervalSince1970 * 1000),
      ])

    case "getLatestFft":
      do {
        result(try engine.getLatestFft())
      } catch {
        sendPlayerState(error: error.localizedDescription)
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
        sendPlayerState(error: error.localizedDescription)
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
        sendPlayerState(error: error.localizedDescription)
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
        sendPlayerState(error: error.localizedDescription)
        result(FlutterError(code: "PCM_FAILED", message: error.localizedDescription, details: nil))
      }

    case "prepareForFileWrite":
      let path = Self.readString(call.arguments, key: "path")
      do {
        try engine.prepareForFileWrite(path: path)
        sendPlayerState()
        result(nil)
      } catch {
        sendPlayerState(error: error.localizedDescription)
        result(FlutterError(code: "PREPARE_FAILED", message: error.localizedDescription, details: nil))
      }

    case "finishFileWrite":
      let path = Self.readString(call.arguments, key: "path")
      do {
        try engine.finishFileWrite(path: path)
        sendPlayerState()
        result(nil)
      } catch {
        sendPlayerState(error: error.localizedDescription)
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
      audioSessionManager.stopObserving()
      audioSessionManager.deactivate()
      shouldResumeAfterInterruption = false
#endif
      sendPlayerState()
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func sendPlayerState(playbackState: String? = nil, error: String? = nil) {
    guard let channel else { return }
    DispatchQueue.main.async {
      channel.invokeMethod(
        "onPlayerStateChanged",
        arguments: self.engine.statusPayload(playbackState: playbackState, error: error)
      )
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

#if os(iOS)
  private func registerAudioSessionObservers() {
    audioSessionManager.observe(
      interruption: { [weak self] notification in
        self?.handleInterruption(notification)
      },
      routeChange: { [weak self] notification in
        self?.handleRouteChange(notification)
      }
    )
  }

  private func activateAudioSession() throws {
    try audioSessionManager.activate()
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
          try audioSessionManager.activate()
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
