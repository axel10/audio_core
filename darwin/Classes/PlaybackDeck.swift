import AVFoundation
import Foundation

final class PlaybackDeck {
  var playerNode = AVAudioPlayerNode()
  var loadedURL: URL?
  var loadedFile: AVAudioFile?
  var analysisFile: AVAudioFile?
  var loadedFFmpegPCM: AppleFFmpegDecodedAudio?
  var loadedFFmpegStream: AppleFFmpegStreamAudio?
  var sampleRate: Double = 44_100
  var playbackFramePosition: AVAudioFramePosition = 0
  var isPlaybackScheduled = false
  var gain: Double = 1.0
  var playbackGeneration: UInt64 = 0
  var scheduledPCMBuffers: [AVAudioPCMBuffer] = []

  var isLoaded: Bool {
    loadedFile != nil || loadedFFmpegPCM != nil || loadedFFmpegStream != nil
  }

  var channelCount: Int {
    if let loadedFile {
      return Int(loadedFile.processingFormat.channelCount)
    }
    if let loadedFFmpegStream {
      return loadedFFmpegStream.channelCount
    }
    return loadedFFmpegPCM?.channelCount ?? 0
  }

  var frameCount: AVAudioFramePosition {
    if let loadedFile {
      return loadedFile.length
    }
    if let loadedFFmpegStream {
      return loadedFFmpegStream.frameCount
    }
    return loadedFFmpegPCM?.frameCount ?? 0
  }

  var ffmpegPCM: AppleFFmpegDecodedAudio? {
    loadedFFmpegPCM
  }

  var usesFFmpegPCM: Bool {
    loadedFFmpegPCM != nil
  }

  var isPlaying: Bool {
    playerNode.isPlaying
  }

  func currentPlaybackFramePosition() -> AVAudioFramePosition {
    let totalFrames = frameCount
    guard totalFrames > 0 else { return playbackFramePosition }
    guard playerNode.isPlaying,
          let nodeTime = playerNode.lastRenderTime,
          let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
      return max(0, min(playbackFramePosition, totalFrames))
    }

    let renderedFrames = max(0, Double(playerTime.sampleTime))
    let playbackSampleRate = playerTime.sampleRate > 0 ? playerTime.sampleRate : sampleRate
    guard playbackSampleRate > 0, sampleRate > 0 else {
      return max(0, min(playbackFramePosition, totalFrames))
    }

    let sourceSampleRate = sampleRate
    let renderedSourceFrames = renderedFrames * (sourceSampleRate / playbackSampleRate)
    let currentFrame = Double(playbackFramePosition) + renderedSourceFrames
    return max(0, min(AVAudioFramePosition(currentFrame.rounded()), totalFrames))
  }

  func invalidatePendingPlaybackCallbacks() {
    playbackGeneration &+= 1
    scheduledPCMBuffers.removeAll()
  }

  func stopPlaybackNode() {
    invalidatePendingPlaybackCallbacks()
    playerNode.stop()
    isPlaybackScheduled = false
  }

  func clear(releasingFile: Bool) {
    stopPlaybackNode()
    if releasingFile {
      loadedURL = nil
      loadedFile = nil
      analysisFile = nil
      loadedFFmpegPCM = nil
      loadedFFmpegStream?.close()
      loadedFFmpegStream = nil
    }
  }
}
