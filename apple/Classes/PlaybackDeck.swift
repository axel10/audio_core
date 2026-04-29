import AVFoundation
import Foundation

final class PlaybackDeck {
  var playerNode = AVAudioPlayerNode()
  var loadedURL: URL?
  var loadedFile: AVAudioFile?
  var sampleRate: Double = 44_100
  var playbackFramePosition: AVAudioFramePosition = 0
  var isPlaybackScheduled = false
  var gain: Double = 1.0
  var playbackGeneration: UInt64 = 0

  var isLoaded: Bool {
    loadedFile != nil
  }

  var isPlaying: Bool {
    playerNode.isPlaying
  }

  func currentPlaybackFramePosition() -> AVAudioFramePosition {
    guard let currentFile = loadedFile else { return playbackFramePosition }
    guard playerNode.isPlaying,
          let nodeTime = playerNode.lastRenderTime,
          let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
      return max(0, min(playbackFramePosition, currentFile.length))
    }

    let renderedFrames = max(0, Double(playerTime.sampleTime))
    let playbackSampleRate = playerTime.sampleRate > 0 ? playerTime.sampleRate : sampleRate
    guard playbackSampleRate > 0, sampleRate > 0 else {
      return max(0, min(playbackFramePosition, currentFile.length))
    }

    let sourceSampleRate = sampleRate
    let renderedSourceFrames = renderedFrames * (sourceSampleRate / playbackSampleRate)
    let currentFrame = Double(playbackFramePosition) + renderedSourceFrames
    return max(0, min(AVAudioFramePosition(currentFrame.rounded()), currentFile.length))
  }

  func invalidatePendingPlaybackCallbacks() {
    playbackGeneration &+= 1
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
    }
  }
}
