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

    let renderedFrames = max(0, playerTime.sampleTime)
    return max(0, min(playbackFramePosition + renderedFrames, currentFile.length))
  }

  func clear(releasingFile: Bool) {
    playerNode.stop()
    isPlaybackScheduled = false
    if releasingFile {
      loadedURL = nil
      loadedFile = nil
    }
  }
}
