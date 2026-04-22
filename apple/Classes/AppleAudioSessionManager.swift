import AVFoundation
import Foundation

#if os(iOS)
final class AppleAudioSessionManager {
  private let audioSession = AVAudioSession.sharedInstance()
  private var notificationTokens: [NSObjectProtocol] = []

  deinit {
    stopObserving()
  }

  func configure() {
    do {
      try audioSession.setCategory(
        .playback,
        mode: .default,
        options: [.allowAirPlay, .allowBluetooth, .allowBluetoothA2DP]
      )
    } catch {
      debugPrint("AppleAudioSessionManager: failed to configure AVAudioSession: \(error)")
    }
  }

  func activate() throws {
    try audioSession.setCategory(
      .playback,
      mode: .default,
      options: [.allowAirPlay, .allowBluetooth, .allowBluetoothA2DP]
    )
    try audioSession.setActive(true, options: [])
  }

  func deactivate() {
    do {
      try audioSession.setActive(false, options: [.notifyOthersOnDeactivation])
    } catch {
      debugPrint("AppleAudioSessionManager: failed to deactivate AVAudioSession: \(error)")
    }
  }

  func observe(
    interruption: @escaping (Notification) -> Void,
    routeChange: @escaping (Notification) -> Void
  ) {
    stopObserving()
    let center = NotificationCenter.default
    notificationTokens.append(
      center.addObserver(
        forName: AVAudioSession.interruptionNotification,
        object: audioSession,
        queue: .main
      ) { notification in
        interruption(notification)
      }
    )
    notificationTokens.append(
      center.addObserver(
        forName: AVAudioSession.routeChangeNotification,
        object: audioSession,
        queue: .main
      ) { notification in
        routeChange(notification)
      }
    )
  }

  func stopObserving() {
    let center = NotificationCenter.default
    notificationTokens.forEach { center.removeObserver($0) }
    notificationTokens.removeAll()
  }
}
#endif
