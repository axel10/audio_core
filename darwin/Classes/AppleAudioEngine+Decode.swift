import AVFoundation
import Foundation

enum AppleAudioLoadBackend {
  case avFoundation
  case ffmpeg
}

enum AppleAudioSampleSource {
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

extension AppleAudioEngine {
  func preferredLoadBackend(for url: URL) -> AppleAudioLoadBackend {
    let preferredExtension = url.pathExtension.lowercased()
    if avFoundationPreferredExtensions.contains(preferredExtension) {
      return .avFoundation
    }
    return .ffmpeg
  }

  func decodeAsset(for url: URL) throws -> AppleAudioSampleSource {
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

  func loadAsset(into deck: PlaybackDeck, from url: URL) throws {
    let startMs = currentTimestampMs()
    switch preferredLoadBackend(for: url) {
    case .avFoundation:
      let source = try decodeAsset(for: url)
      switch source {
      case .avFoundation(let file):
        assignLoadedAsset(
          into: deck,
          url: url,
          sampleRate: file.processingFormat.sampleRate,
          loadedFile: file,
          loadedFFmpegPCM: nil,
          loadedFFmpegStream: nil
        )
      case .ffmpeg(let decoded):
        // Some files can advertise AVFoundation support but still fail on Apple.
        // Keep the legacy fallback for those rare cases.
        let targetSampleRate = playbackSampleRate()
        let playbackPCM = try decoded.resampled(to: targetSampleRate)
        assignLoadedAsset(
          into: deck,
          url: url,
          sampleRate: playbackPCM.sampleRate,
          loadedFile: nil,
          loadedFFmpegPCM: playbackPCM,
          loadedFFmpegStream: nil
        )
      case .ffmpegStream:
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
      assignLoadedAsset(
        into: deck,
        url: url,
        sampleRate: playbackStream.sampleRate,
        loadedFile: nil,
        loadedFFmpegPCM: nil,
        loadedFFmpegStream: playbackStream
      )
    }
    deck.playbackFramePosition = 0
    deck.isPlaybackScheduled = false
    deck.gain = 1.0
    syncOnFfmpegPlaybackQueue {
      deck.scheduledPCMBuffers.removeAll()
    }
    resetFftCaptureBuffer()
    debugPrint(
      "[AppleAudioEngine] loadAsset done path=\(url.path) source=\(deck.sampleRate) " +
      "elapsedMs=\(String(format: "%.1f", currentTimestampMs() - startMs))"
    )
  }

  func assignLoadedAsset(
    into deck: PlaybackDeck,
    url: URL,
    sampleRate: Double,
    loadedFile: AVAudioFile?,
    loadedFFmpegPCM: AppleFFmpegDecodedAudio?,
    loadedFFmpegStream: AppleFFmpegStreamAudio?
  ) {
    deck.sampleRate = sampleRate
    deck.loadedURL = url
    deck.loadedFile = loadedFile
    deck.loadedFFmpegPCM = loadedFFmpegPCM
    deck.loadedFFmpegStream = loadedFFmpegStream
  }

  func configureEngineIfNeeded() {
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

  func startPlaybackIfNeeded(
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
    drainDeckFfmpegPlaybackState(deck, releasingFile: false)
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

  func schedulePlaybackSegment(
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

  func scheduleFFmpegPlayback(
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
    var scheduledChunkCount = 0
    syncOnFfmpegPlaybackQueue {
      deck.scheduledPCMBuffers.removeAll()
    }

    debugPrint(
      "[AppleAudioEngine] ffmpeg schedule start path=\(deck.loadedURL?.path ?? "nil") " +
      "startFrame=\(startFrame) totalFrames=\(totalFrames) lookahead=\(ffmpegPlaybackLookaheadBuffers)"
    )

    func scheduleNextBuffer() -> Bool {
      guard nextFrameToSchedule < totalFrames else {
        return false
      }

      let decodeStartMs = currentTimestampMs()
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

      let chunkIndex = scheduledChunkCount
      scheduledChunkCount += 1
      nextFrameToSchedule = min(totalFrames, bufferStart + bufferFrameCount)
      let isLastBuffer = nextFrameToSchedule >= totalFrames
      let bufferedUntilFrame = nextFrameToSchedule
      let decodeElapsedMs = currentTimestampMs() - decodeStartMs
      let bufferDurationMs = framePositionToMilliseconds(bufferFrameCount, sampleRate: deck.sampleRate)
      if deck.scheduledPCMBuffers.count >= ffmpegPlaybackLookaheadBuffers {
        deck.scheduledPCMBuffers.removeFirst()
      }
      deck.scheduledPCMBuffers.append(buffer)
      debugPrint(
        "[AppleAudioEngine] ffmpeg schedule chunk path=\(deck.loadedURL?.path ?? "nil") " +
        "index=\(chunkIndex) startFrame=\(bufferStart) frames=\(bufferFrameCount) " +
        "durationMs=\(bufferDurationMs) bufferedUntilFrame=\(bufferedUntilFrame) " +
        "decodeElapsedMs=\(String(format: "%.1f", decodeElapsedMs)) queueDepth=\(deck.scheduledPCMBuffers.count)"
      )

      let completion: (AVAudioPCMBuffer) -> Void = { [weak self] _ in
        guard let self = self else { return }
        let callbackAtMs = self.currentTimestampMs()
        self.ffmpegPlaybackQueue.async {
          guard deck.playbackGeneration == generation, deck.isPlaybackScheduled else {
            return
          }
          let callbackDeltaMs = self.currentTimestampMs() - callbackAtMs
          let playbackFrame = deck.currentPlaybackFramePosition()
          debugPrint(
            "[AppleAudioEngine] ffmpeg chunk callback path=\(deck.loadedURL?.path ?? "nil") " +
            "index=\(chunkIndex) kind=\(isLastBuffer ? "playedBack" : "rendered") " +
            "bufferStart=\(bufferStart) frames=\(bufferFrameCount) playbackFrame=\(playbackFrame) " +
            "dispatchDelayMs=\(String(format: "%.1f", callbackDeltaMs)) queueDepthBefore=\(deck.scheduledPCMBuffers.count)"
          )
          if isLastBuffer {
            self.handlePlaybackCompleted(
              deck: deck,
              generation: generation,
              expectedPath: expectedPath
            )
            return
          }

          if !deck.scheduledPCMBuffers.isEmpty {
            deck.scheduledPCMBuffers.removeFirst()
          }
          if !scheduleNextBuffer() {
            debugPrint(
              "[AppleAudioEngine] ffmpeg schedule refill failed path=\(deck.loadedURL?.path ?? "nil") " +
              "generation=\(generation)"
            )
            self.handlePlaybackCompleted(
              deck: deck,
              generation: generation,
              expectedPath: expectedPath
            )
          }
        }
      }

      if #available(macOS 10.13, iOS 11.0, *) {
        deck.playerNode.scheduleBuffer(
          buffer,
          at: nil,
          options: [],
          completionCallbackType: isLastBuffer ? .dataPlayedBack : .dataRendered,
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
    let queuedBufferCount = syncOnFfmpegPlaybackQueueValue {
      deck.scheduledPCMBuffers.count
    }
    debugPrint(
      "[AppleAudioEngine] ffmpeg schedule initial queued=\(queuedBufferCount) " +
      "elapsedMs=\(String(format: "%.1f", currentTimestampMs() - startMs))"
    )
    return true
  }

  func scheduleLegacyFFmpegPlayback(
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
    syncOnFfmpegPlaybackQueue {
      deck.scheduledPCMBuffers = buffers
    }

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

  func scheduleLegacyPlaybackCompletionCheck(
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

  func verifyLegacyPlaybackCompletion(
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
}
