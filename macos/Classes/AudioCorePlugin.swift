import AVFoundation
import Foundation
import FlutterMacOS

public final class AudioCorePlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private let fileAccess = SecurityScopedFileAccessCoordinator()
  private let engine: AppleAudioEngine
  private var channel: FlutterMethodChannel?
  private var fftEventChannel: FlutterEventChannel?
  private var fftEventSink: FlutterEventSink?
  private var fftTimer: Timer?
  private var fftEmissionInFlight = false

  public override init() {
    self.engine = AppleAudioEngine(fileAccess: fileAccess)
    super.init()
    self.engine.onPlayerStateChanged = { [weak self] playbackState, error in
      self?.sendPlayerState(playbackState: playbackState, error: error)
    }
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "audio_core.player",
      binaryMessenger: registrar.messenger
    )
    let fftChannel = FlutterEventChannel(
      name: "audio_core.player/fft",
      binaryMessenger: registrar.messenger
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
        emitLatestFftSnapshot()
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
        emitLatestFftSnapshot()
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

    case "beginScopedAccess":
      guard let path = Self.readString(call.arguments, key: "path") else {
        result(false)
        return
      }
      result(engine.beginScopedAccess(path: path))

    case "endScopedAccess":
      guard let path = Self.readString(call.arguments, key: "path") else {
        result(nil)
        return
      }
      engine.endScopedAccess(path: path)
      result(nil)

    case "dispose":
      debugPrint("[AudioCorePlugin] method=dispose")
      engine.dispose()
      stopFftStreaming()
      fftEventSink = nil
      sendPlayerState()
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
    startFftStreaming()
    emitLatestFftSnapshot()
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    stopFftStreaming()
    fftEventSink = nil
    return nil
  }

  private func sendPlayerState(playbackState: String? = nil, error: String? = nil) {
    guard let channel else { return }
    let payload = engine.statusPayload(playbackState: playbackState, error: error)
    let stateText = String(describing: payload["state"] ?? "nil")
    let pathText = String(describing: payload["path"] ?? "nil")
    let positionText = String(describing: payload["position"] ?? "nil")
    let durationText = String(describing: payload["duration"] ?? "nil")
    let playingText = String(describing: payload["isPlaying"] ?? "nil")
    let errorText = String(describing: payload["error"] ?? "nil")
    debugPrint(
      "[AudioCorePlugin] emit state=\(stateText) " +
      "path=\(pathText) pos=\(positionText) " +
      "dur=\(durationText) playing=\(playingText) " +
      "error=\(errorText)"
    )
    DispatchQueue.main.async {
      channel.invokeMethod(
        "onPlayerStateChanged",
        arguments: payload
      )
    }
  }

  private func startFftStreaming() {
    guard fftTimer == nil else { return }
    fftTimer = Timer.scheduledTimer(
      withTimeInterval: 1.0 / 30.0,
      repeats: true
    ) { [weak self] _ in
      self?.emitLatestFftSnapshot()
    }
    if let fftTimer {
      RunLoop.main.add(fftTimer, forMode: .common)
    }
  }

  private func stopFftStreaming() {
    fftTimer?.invalidate()
    fftTimer = nil
    fftEmissionInFlight = false
  }

  private func emitLatestFftSnapshot() {
    guard let sink = fftEventSink, !fftEmissionInFlight else { return }
    fftEmissionInFlight = true
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      let values: [Double]
      do {
        values = try self.engine.getLatestFft()
      } catch {
        values = []
        DispatchQueue.main.async {
          self.sendPlayerState(error: error.localizedDescription)
        }
      }

      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        defer { self.fftEmissionInFlight = false }
        guard let sink = self.fftEventSink else { return }
        sink([
          "playerId": "main",
          "values": values,
        ])
      }
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
}
