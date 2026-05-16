import AVFoundation
import Foundation

extension AppleAudioEngine {
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
    removePreparedAccessPath(url.path)
    debugPrint(
      "[AppleAudioEngine] load done path=\(path) sampleRate=\(currentDeck.sampleRate) " +
      "length=\(currentDeck.frameCount) elapsedMs=\(String(format: "%.1f", currentTimestampMs() - startMs)) " +
      "public=\(publicURL()?.path ?? "nil")"
    )
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

  func emitPlayerState(playbackState: String? = nil, error: String? = nil) {
    onPlayerStateChanged?(playbackState, error)
  }

  func currentPlaybackState() -> String {
    guard let deck = publicDeck() else {
      return "IDLE"
    }
    if deck.isPlaying {
      return "PLAYING"
    }

    if deck.frameCount > 0, deck.currentPlaybackFramePosition() >= deck.frameCount {
      return "ENDED"
    }
    if deck.currentPlaybackFramePosition() > 0 {
      return "PAUSED"
    }
    return deck.isLoaded ? "READY" : "IDLE"
  }

  func publicDeck() -> PlaybackDeck? {
    if incomingDeck.isLoaded {
      return incomingDeck
    }
    if currentDeck.isLoaded {
      return currentDeck
    }
    return nil
  }

  func publicURL() -> URL? {
    publicDeck()?.loadedURL
  }

  func publicFile() -> AVAudioFile? {
    publicDeck()?.loadedFile
  }

  func publicSampleRate() -> Double {
    publicDeck()?.sampleRate ?? 44_100
  }

  func playbackSampleRate() -> Double {
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

  func publicFrameCount() -> AVAudioFramePosition {
    publicDeck()?.frameCount ?? 0
  }

  func publicChannelCount() -> Int {
    publicDeck()?.channelCount ?? 0
  }

  func framePosition(forMilliseconds milliseconds: Int, sampleRate: Double) -> AVAudioFramePosition {
    guard sampleRate > 0 else { return 0 }
    let frame = (Double(milliseconds) / 1000.0) * sampleRate
    return AVAudioFramePosition(frame.rounded(.down))
  }

  func frameCountToMilliseconds(_ frameCount: AVAudioFramePosition, sampleRate: Double) -> Int {
    framePositionToMilliseconds(frameCount, sampleRate: sampleRate)
  }

  func framePositionToMilliseconds(_ framePosition: AVAudioFramePosition, sampleRate: Double) -> Int {
    guard sampleRate > 0 else { return 0 }
    return max(0, Int(((Double(framePosition) / sampleRate) * 1000.0).rounded()))
  }
}
