import AVFoundation
import Foundation

#if os(iOS)
import Flutter
#elseif os(macOS)
import FlutterMacOS
#endif

public final class AudioCorePlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private let fileAccess = SecurityScopedFileAccessCoordinator()
  private let engine: AppleAudioEngine
  private var channel: FlutterMethodChannel?
  private var fftEventChannel: FlutterEventChannel?
  private var fftEventSink: FlutterEventSink?
  private var fftTimer: Timer?
  private var fftEmissionInFlight = false
  private var fftEmitCount = 0

  public override init() {
    self.engine = AppleAudioEngine(fileAccess: fileAccess)
    super.init()
    self.engine.onPlayerStateChanged = { [weak self] playbackState, error in
      self?.sendPlayerState(playbackState: playbackState, error: error)
    }
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
    let messenger = registrar.messenger()
    #else
    let messenger = registrar.messenger
    #endif
    let channel = FlutterMethodChannel(
      name: "audio_core.player",
      binaryMessenger: messenger
    )
    let fftChannel = FlutterEventChannel(
      name: "audio_core.player/fft",
      binaryMessenger: messenger
    )
    let instance = AudioCorePlugin()
    instance.channel = channel
    instance.fftEventChannel = fftChannel
    registrar.addMethodCallDelegate(instance, channel: channel)
    fftChannel.setStreamHandler(instance)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "sayHello":
      engine.ensureReady()
      sendPlayerState()
      emitLatestFftSnapshot()
      result(nil)

    case "load":
      guard let args = call.arguments as? [String: Any],
            let path = args["url"] as? String else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "URL is null", details: nil))
        return
      }
      debugPrint("[AudioCorePlugin] method=load path=\(path)")
      do {
        try engine.load(path: path)
        sendPlayerState()
        emitLatestFftSnapshot()
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
      debugPrint(
        "[AudioCorePlugin] method=crossfade path=\(path) durationMs=\(durationMs) " +
        "positionMs=\(positionMs.map(String.init) ?? "nil")"
      )
      do {
        try engine.crossfade(path: path, durationMs: durationMs, positionMs: positionMs)
        sendPlayerState()
        emitLatestFftSnapshot()
        result(nil)
      } catch {
        sendPlayerState(error: error.localizedDescription)
        result(FlutterError(code: "CROSSFADE_FAILED", message: error.localizedDescription, details: nil))
      }

    case "play":
      let fadeDurationMs = Self.readInt(call.arguments, key: "fadeDurationMs") ?? 0
      let targetVolume = Self.readDouble(call.arguments, key: "targetVolume")
      debugPrint(
        "[AudioCorePlugin] method=play fadeDurationMs=\(fadeDurationMs) " +
        "targetVolume=\(targetVolume.map { String(format: "%.3f", $0) } ?? "nil")"
      )
      do {
        try engine.play(fadeDurationMs: fadeDurationMs, targetVolume: targetVolume)
        sendPlayerState()
        emitLatestFftSnapshot()
        result(nil)
      } catch {
        sendPlayerState(error: error.localizedDescription)
        result(FlutterError(code: "PLAY_FAILED", message: error.localizedDescription, details: nil))
      }

    case "pause":
      let fadeDurationMs = Self.readInt(call.arguments, key: "fadeDurationMs") ?? 0
      debugPrint("[AudioCorePlugin] method=pause fadeDurationMs=\(fadeDurationMs)")
      do {
        try engine.pause(fadeDurationMs: fadeDurationMs)
        emitLatestFftSnapshot()
        result(nil)
      } catch {
        sendPlayerState(error: error.localizedDescription)
        result(FlutterError(code: "PAUSE_FAILED", message: error.localizedDescription, details: nil))
      }

    case "seek":
      let positionMs = Self.readInt(call.arguments, key: "position") ?? 0
      debugPrint("[AudioCorePlugin] method=seek positionMs=\(positionMs)")
      do {
        try engine.seek(positionMs: positionMs)
        sendPlayerState()
        emitLatestFftSnapshot()
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
        emitLatestFftSnapshot()
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

    case "configureFftProcessing":
      let frequencyGroups = Self.readInt(call.arguments, key: "frequencyGroups") ?? 32
      let skipHighFrequencyGroups =
        Self.readInt(call.arguments, key: "skipHighFrequencyGroups") ?? 0
      let aggregationMode =
        Self.readString(call.arguments, key: "aggregationMode") ?? "peak"
      engine.updateFftGroupingOptions(
        frequencyGroups: frequencyGroups,
        skipHighFrequencyGroups: skipHighFrequencyGroups,
        aggregationMode: aggregationMode
      )
      emitLatestFftSnapshot()
      result(nil)

    case "getWaveform":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "Path is null", details: nil))
        return
      }
      let expectedChunks = Self.readInt(call.arguments, key: "expectedChunks") ?? 0
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          let waveform = try self.engine.getWaveform(path: path, expectedChunks: expectedChunks)
          DispatchQueue.main.async {
            result(waveform)
          }
        } catch {
          self.sendPlayerState(error: error.localizedDescription)
          DispatchQueue.main.async {
            result(FlutterError(code: "WAVEFORM_FAILED", message: error.localizedDescription, details: nil))
          }
        }
      }

    case "extractFingerprint":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "Path is null", details: nil))
        return
      }
      let expectedChunks = Self.readInt(call.arguments, key: "expectedChunks") ?? 0
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          let fingerprint = try self.engine.extractFingerprint(
            path: path,
            expectedChunks: expectedChunks
          )
          DispatchQueue.main.async {
            result(fingerprint)
          }
        } catch {
          self.sendPlayerState(error: error.localizedDescription)
          DispatchQueue.main.async {
            result(FlutterError(code: "FINGERPRINT_FAILED", message: error.localizedDescription, details: nil))
          }
        }
      }

    case "fitTrackMetadata":
      guard let args = call.arguments as? [String: Any] else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "Arguments are null", details: nil))
        return
      }
      let entry = AudioCorePlugin.readTrackMetadataArgs(args)
      result(engine.fitTrackMetadata(entry))

    case "fitTrackMetadataInLibrary":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "Path is null", details: nil))
        return
      }
      do {
        result(try engine.fitTrackMetadataInLibrary(path: path))
      } catch {
        sendPlayerState(error: error.localizedDescription)
        result(FlutterError(
          code: "FIT_LIBRARY_FAILED",
          message: error.localizedDescription,
          details: nil
        ))
      }

    case "deleteFromLibrary":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "Path is null", details: nil))
        return
      }
      do {
        try engine.deleteFromLibrary(path: path)
        result(nil)
      } catch {
        sendPlayerState(error: error.localizedDescription)
        result(FlutterError(
          code: "DELETE_LIBRARY_FAILED",
          message: error.localizedDescription,
          details: nil
        ))
      }

    case "saveWaveform":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String,
            let data = args["data"] as? [Double] else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "Path or data is null", details: nil))
        return
      }
      do {
        try engine.saveWaveform(path: path, data: data)
        result(nil)
      } catch {
        sendPlayerState(error: error.localizedDescription)
        result(FlutterError(code: "SAVE_WAVEFORM_FAILED", message: error.localizedDescription, details: nil))
      }

    case "addSilenceToWaveform":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String,
            let data = args["data"] as? [Double] else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "Path or data is null", details: nil))
        return
      }
      do {
        try engine.addSilenceToWaveform(path: path, data: data)
        result(nil)
      } catch {
        sendPlayerState(error: error.localizedDescription)
        result(FlutterError(
          code: "ADD_SILENCE_TO_WAVEFORM_FAILED",
          message: error.localizedDescription,
          details: nil
        ))
      }

    case "finishFileWrite":
      let path = Self.readString(call.arguments, key: "path")
      do {
        try engine.finishFileWrite(path: path)
        result(nil)
      } catch {
        sendPlayerState(error: error.localizedDescription)
        result(FlutterError(
          code: "FINISH_FILE_WRITE_FAILED",
          message: error.localizedDescription,
          details: nil
        ))
      }

    case "logMessage":
      let message = Self.readString(call.arguments, key: "message") ?? ""
      let level = Self.readString(call.arguments, key: "level") ?? "info"
      self.logMessage(level: level, message: message)
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  public func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    fftEventSink = events
    startFftTimerIfNeeded()
    emitLatestFftSnapshot()
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    stopFftTimer()
    fftEventSink = nil
    return nil
  }

  private func sendPlayerState(playbackState: String? = nil, error: String? = nil) {
    channel?.invokeMethod(
      "onPlayerStateChanged",
      arguments: engine.statusPayload(playbackState: playbackState, error: error)
    )
  }

  private func emitLatestFftSnapshot() {
    guard !fftEmissionInFlight else { return }
    fftEmissionInFlight = true
    defer { fftEmissionInFlight = false }

    guard let fftEventSink else { return }
    do {
      let fft = try engine.getLatestFft()
      fftEmitCount &+= 1
      if fft.isEmpty || fftEmitCount % 60 == 0 {
        debugPrint(
          "[AudioCorePlugin] fft emit count=\(fftEmitCount) values=\(fft.count) " +
          "first=\(fft.first.map { String(format: "%.6f", $0) } ?? "nil")"
        )
      }
      fftEventSink([
        "type": "fft",
        "payload": [
          "values": fft,
        ],
      ])
    } catch {
      fftEventSink([
        "type": "error",
        "payload": error.localizedDescription,
      ])
    }
  }

  private func startFftTimerIfNeeded() {
    guard fftTimer == nil else { return }
    debugPrint("[AudioCorePlugin] fft timer start")
    fftTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
      self?.emitLatestFftSnapshot()
    }
    if let fftTimer {
      RunLoop.main.add(fftTimer, forMode: .common)
    }
  }

  private func stopFftTimer() {
    guard fftTimer != nil else { return }
    debugPrint("[AudioCorePlugin] fft timer stop")
    fftTimer?.invalidate()
    fftTimer = nil
    fftEmitCount = 0
  }

  private func logMessage(level: String, message: String) {
    switch level.lowercased() {
    case "debug":
      debugPrint("[AudioCorePlugin] \(message)")
    case "warning":
      debugPrint("[AudioCorePlugin][warning] \(message)")
    case "error":
      debugPrint("[AudioCorePlugin][error] \(message)")
    default:
      debugPrint("[AudioCorePlugin] \(message)")
    }
  }

  private static func readInt(_ arguments: Any?, key: String) -> Int? {
    guard let args = arguments as? [String: Any] else { return nil }
    if let value = args[key] as? Int { return value }
    if let value = args[key] as? Double { return Int(value) }
    if let value = args[key] as? NSNumber { return value.intValue }
    return nil
  }

  private static func readDouble(_ arguments: Any?, key: String) -> Double? {
    guard let args = arguments as? [String: Any] else { return nil }
    if let value = args[key] as? Double { return value }
    if let value = args[key] as? Int { return Double(value) }
    if let value = args[key] as? NSNumber { return value.doubleValue }
    return nil
  }

  private static func readString(_ arguments: Any?, key: String) -> String? {
    guard let args = arguments as? [String: Any] else { return nil }
    return args[key] as? String
  }

  private static func readTrackMetadataArgs(_ args: [String: Any]) -> [String: Any] {
    args
  }
}
