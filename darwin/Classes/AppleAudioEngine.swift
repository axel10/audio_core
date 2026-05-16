import Accelerate
import AVFoundation
import Foundation

final class AppleAudioEngine {
  struct PendingEdit {
    let path: String
    let positionMs: Int
    let wasPlaying: Bool
    let volume: Double
  }

  let fftSize = 1024
  let fftBinCount = 512
  let fftLog2Size: vDSP_Length = 9
  let fftHopSize = 512
  let fftFrameQueueCapacity = 24
  // macOS UI handoffs such as NSOpenPanel or app switching can briefly starve
  // background scheduling. Keep a larger FFmpeg PCM runway than the
  // AVFoundation path needs so playback stays smooth across those transitions.
  let ffmpegScheduleChunkFrames = 16_384
  let ffmpegPlaybackLookaheadBuffers = 6
  let ffmpegPlaybackQueue = DispatchQueue(label: "audio_core.ffmpeg.playback", qos: .userInitiated)
  let ffmpegPlaybackQueueKey = DispatchSpecificKey<Void>()
  let fftProcessingQueue = DispatchQueue(label: "audio_core.fft.processing", qos: .userInitiated)
  let waveformRmsWindowsPerChunk = 8
  let waveformPrecisionScale = 100.0
  let avFoundationPreferredExtensions: Set<String> = [
    "aac", "aif", "aiff", "caf", "m4a", "m4p", "mp3", "mp4", "m4v", "mov", "wav"
  ]
  let fileAccess: SecurityScopedFileAccessCoordinator
  let engine = AVAudioEngine()
  let deckMixerNode = AVAudioMixerNode()
  let equalizerNode = AVAudioUnitEQ(numberOfBands: AppleEqualizerDefaults.maxBands + 1)
  let currentDeck = PlaybackDeck()
  let incomingDeck = PlaybackDeck()
  var latestVolume: Double = 1.0
  var latestEqualizerConfig = AppleEqualizerCodec.defaultConfig()
  var pendingEdit: PendingEdit?
  var fadeTimer: Timer?
  var fadeGeneration: UInt64 = 0
  var preparedAccessPaths = Set<String>()
  var isEngineConfigured = false
  var fftGroupingConfig = AppleFftGroupingConfig()
  let fftSetup: FFTSetup?
  let fftWorkspace: AppleFftWorkspace
  let fftCaptureBuffer = AppleFftRingBuffer(capacity: 16_384)
  let fftResultLock = NSLock()
  var latestRawFft: [Double]
  var latestRawTapMagnitudes: [Double]
  var fftAnalysisRemainder: [Float] = []
  var pendingFftFrames: [[Double]] = []
  var fftTapCount: Int = 0
  var fftLastTapAtMs: Double?
  var fftLastFetchAtMs: Double?
  var isFftTapInstalled = false
  var fftProcessingGeneration: UInt64 = 0

  var onPlayerStateChanged: ((String?, String?) -> Void)?

  init(fileAccess: SecurityScopedFileAccessCoordinator) {
    self.fileAccess = fileAccess
    self.fftSetup = vDSP_create_fftsetup(fftLog2Size, FFTRadix(kFFTRadix2))
    self.fftWorkspace = AppleFftWorkspace(fftSize: 1024)
    self.latestRawFft = Array(repeating: 0.0, count: fftBinCount)
    self.latestRawTapMagnitudes = Array(repeating: 0.0, count: fftBinCount)
    ffmpegPlaybackQueue.setSpecific(key: ffmpegPlaybackQueueKey, value: ())
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

  func currentTimestampMs() -> Double {
    CFAbsoluteTimeGetCurrent() * 1000.0
  }

  func syncOnFfmpegPlaybackQueue(_ work: () -> Void) {
    if DispatchQueue.getSpecific(key: ffmpegPlaybackQueueKey) != nil {
      work()
      return
    }
    ffmpegPlaybackQueue.sync(execute: work)
  }

  func syncOnFfmpegPlaybackQueueValue<T>(_ work: () -> T) -> T {
    if DispatchQueue.getSpecific(key: ffmpegPlaybackQueueKey) != nil {
      return work()
    }
    return ffmpegPlaybackQueue.sync(execute: work)
  }

  func drainDeckFfmpegPlaybackState(_ deck: PlaybackDeck, releasingFile: Bool) {
    syncOnFfmpegPlaybackQueue {
      deck.scheduledPCMBuffers.removeAll()
      if releasingFile {
        deck.loadedFFmpegStream?.close()
        deck.loadedFFmpegStream = nil
      } else {
        deck.loadedFFmpegStream?.close()
      }
    }
  }
}
