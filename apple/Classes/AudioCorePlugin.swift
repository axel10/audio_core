import AVFoundation
import Foundation

#if os(macOS)
import FlutterMacOS
#else
import Flutter
#endif

public final class AudioCorePlugin: NSObject, FlutterPlugin {
  private let engine = AppleAudioEngine()
  private var channel: FlutterMethodChannel?

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
      do {
        try engine.prepareForFileWrite()
        sendPlayerState()
        result(nil)
      } catch {
        result(FlutterError(code: "PREPARE_FAILED", message: error.localizedDescription, details: nil))
      }
    case "finishFileWrite":
      do {
        try engine.finishFileWrite()
        sendPlayerState()
        result(nil)
      } catch {
        result(FlutterError(code: "FINISH_FAILED", message: error.localizedDescription, details: nil))
      }
    case "dispose":
      engine.dispose()
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
    return nil
  }

  private static func readDouble(_ arguments: Any?, key: String) -> Double? {
    guard let map = arguments as? [String: Any] else { return nil }
    if let value = map[key] as? Double { return value }
    if let value = map[key] as? Int { return Double(value) }
    if let value = map[key] as? Int64 { return Double(value) }
    return nil
  }
}

private final class AppleAudioEngine {
  private struct PendingEdit {
    let path: String
    let positionMs: Int
    let wasPlaying: Bool
    let volume: Double
  }

  private let fftSize = 1024
  private let fftBinCount = 512
  private var player: AVAudioPlayer?
  private var currentURL: URL?
  private var sampleRate: Double = 44_100
  private var latestVolume: Double = 1.0
  private var pendingEdit: PendingEdit?
  private var fadeTimer: Timer?

  func ensureReady() {
    // The native engine is lazy; no-op here keeps the channel contract simple.
  }

  func load(path: String) throws {
    let url = try resolveURL(path)
    let audioPlayer = try AVAudioPlayer(contentsOf: url)
    audioPlayer.numberOfLoops = 0
    audioPlayer.prepareToPlay()
    audioPlayer.volume = Float(latestVolume)

    let file = try AVAudioFile(forReading: url)
    sampleRate = file.processingFormat.sampleRate
    currentURL = url
    player = audioPlayer
  }

  func crossfade(path: String, durationMs: Int) throws {
    try load(path: path)
    try play(fadeDurationMs: durationMs, targetVolume: latestVolume)
  }

  func play(fadeDurationMs: Int, targetVolume: Double?) throws {
    guard let player else {
      throw NSError(
        domain: "AudioCore",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "audio is not loaded"]
      )
    }

    let target = (targetVolume ?? latestVolume).clamped(to: 0.0...1.0)
    latestVolume = target
    if fadeDurationMs > 0 {
      player.volume = 0.0
      player.play()
      fadeVolume(from: 0.0, to: target, durationMs: fadeDurationMs) { [weak self] in
        self?.player?.volume = Float(target)
      }
    } else {
      player.volume = Float(target)
      player.play()
    }
  }

  func pause(fadeDurationMs: Int) throws {
    guard let player else { return }

    if fadeDurationMs > 0 {
      let originalVolume = Double(player.volume)
      fadeVolume(from: originalVolume, to: 0.0, durationMs: fadeDurationMs) { [weak self] in
        guard let self else { return }
        player.pause()
        player.volume = Float(self.latestVolume)
      }
    } else {
      player.pause()
    }
  }

  func seek(positionMs: Int) throws {
    guard let player else {
      throw NSError(
        domain: "AudioCore",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "audio is not loaded"]
      )
    }
    player.currentTime = max(0.0, Double(positionMs) / 1000.0)
  }

  func setVolume(_ volume: Double) throws {
    let clamped = volume.clamped(to: 0.0...1.0)
    latestVolume = clamped
    player?.volume = Float(clamped)
  }

  func getDurationMs() -> Int {
    guard let player else { return 0 }
    return max(0, Int((player.duration * 1000.0).rounded()))
  }

  func getCurrentPositionMs() -> Int {
    guard let player else { return 0 }
    return max(0, Int((player.currentTime * 1000.0).rounded()))
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
    let url = try resolveURL(path)
    return try readInterleavedPCM(url: url, sampleStride: sampleStride)
  }

  func getAudioPcmChannelCount(path: String) throws -> Int {
    let url = try resolveURL(path)
    let file = try AVAudioFile(forReading: url)
    return Int(file.processingFormat.channelCount)
  }

  func getFingerprintPcm(path: String, maxDurationMs: Int) throws -> [String: Any] {
    let url = try resolveURL(path)
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

  func prepareForFileWrite() throws {
    guard let path = currentURL?.path else { return }
    let wasPlaying = player?.isPlaying ?? false
    let positionMs = getCurrentPositionMs()
    let volume = latestVolume
    pendingEdit = PendingEdit(
      path: path,
      positionMs: positionMs,
      wasPlaying: wasPlaying,
      volume: volume
    )
    player?.stop()
    player = nil
  }

  func finishFileWrite() throws {
    guard let pendingEdit else { return }
    try load(path: pendingEdit.path)
    try seek(positionMs: pendingEdit.positionMs)
    try setVolume(pendingEdit.volume)
    if pendingEdit.wasPlaying {
      try play(fadeDurationMs: 0, targetVolume: pendingEdit.volume)
    }
    self.pendingEdit = nil
  }

  func dispose() {
    fadeTimer?.invalidate()
    fadeTimer = nil
    pendingEdit = nil
    player?.stop()
    player = nil
    currentURL = nil
  }

  func statusPayload() -> [String: Any] {
    var payload: [String: Any] = [
      "playerId": "main",
      "position": getCurrentPositionMs(),
      "duration": getDurationMs(),
      "isPlaying": player?.isPlaying ?? false,
      "volume": latestVolume,
    ]
    if let path = currentURL?.path {
      payload["path"] = path
    }
    return payload
  }

  private func resolveURL(_ path: String) throws -> URL {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      throw NSError(
        domain: "AudioCore",
        code: 3,
        userInfo: [NSLocalizedDescriptionKey: "path is empty"]
      )
    }
    if let url = URL(string: trimmed), url.isFileURL {
      return url
    }
    if trimmed.hasPrefix("file://"), let url = URL(string: trimmed) {
      return url
    }
    return URL(fileURLWithPath: trimmed)
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
      self.player?.volume = Float(nextVolume.clamped(to: 0.0...1.0))
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
