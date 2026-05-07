import AVFoundation
import Foundation

extension AppleAudioEngine {
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

  func handlePlaybackCompleted(
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

  func stopPlayback(releasingFile: Bool, preservePosition: Bool) {
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

  func pausePlayback(preservePosition: Bool) {
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

  func restoreDeckVolumes() {
    if currentDeck.isLoaded {
      currentDeck.playerNode.volume = Float((latestVolume * currentDeck.gain).clamped(to: 0.0...1.0))
    }
    if incomingDeck.isLoaded {
      incomingDeck.playerNode.volume = Float((latestVolume * incomingDeck.gain).clamped(to: 0.0...1.0))
    }
  }

  func releaseCurrentAccessIfNeeded() {
    guard let currentURL = currentDeck.loadedURL else { return }
    fileAccess.releaseAccess(for: currentURL)
    currentDeck.loadedURL = nil
  }

  func startCrossfade(path: String, durationMs: Int, positionMs: Int?) throws {
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

  func settleCrossfade() {
    debugPrint(
      "[AppleAudioEngine] settleCrossfade start current=\(currentDeck.loadedURL?.path ?? "nil") " +
      "incoming=\(incomingDeck.loadedURL?.path ?? "nil")"
    )
    guard incomingDeck.loadedFile != nil || incomingDeck.loadedFFmpegStream != nil else { return }

    if let oldURL = currentDeck.loadedURL {
      fileAccess.releaseAccess(for: oldURL)
    }

    let shouldRescheduleFFmpegStream = incomingDeck.loadedFFmpegStream != nil
    let resumedFrame = shouldRescheduleFFmpegStream
      ? incomingDeck.currentPlaybackFramePosition()
      : 0

    swap(&currentDeck.playerNode, &incomingDeck.playerNode)
    swap(&currentDeck.loadedURL, &incomingDeck.loadedURL)
    swap(&currentDeck.loadedFile, &incomingDeck.loadedFile)
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

    if shouldRescheduleFFmpegStream {
      // FFmpeg stream buffer completion callbacks capture the deck object used
      // during scheduling. After the deck-role swap above, the newly current
      // deck must be re-scheduled so future refill callbacks target the active
      // deck instead of the old incoming one.
      let clampedResumeFrame = max(0, min(resumedFrame, currentDeck.frameCount))
      currentDeck.playbackFramePosition = clampedResumeFrame
      currentDeck.stopPlaybackNode()
      do {
        try startPlaybackIfNeeded(
          on: currentDeck,
          from: clampedResumeFrame,
          volume: latestVolume
        )
      } catch {
        debugPrint(
          "[AppleAudioEngine] settleCrossfade ffmpeg reschedule failed path=\(currentDeck.loadedURL?.path ?? "nil") " +
          "frame=\(clampedResumeFrame) error=\(error.localizedDescription)"
        )
      }
    }

    incomingDeck.clear(releasingFile: true)
    if let currentURL = currentDeck.loadedURL {
      preparedAccessPaths.remove(currentURL.path)
    }
    debugPrint(
      "[AppleAudioEngine] settleCrossfade done current=\(currentDeck.loadedURL?.path ?? "nil") " +
      "incoming=\(incomingDeck.loadedURL?.path ?? "nil")"
    )
  }

  func fadeVolume(
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
}
