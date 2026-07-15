import AVFoundation
import Foundation

#if os(iOS)
import Flutter
#elseif os(macOS)
import FlutterMacOS
#endif

public final class AudioCorePlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private static var shared: AudioCorePlugin?
  private let fileAccess = SecurityScopedFileAccessCoordinator()
  private var channel: FlutterMethodChannel?
  private var converterChannel: FlutterMethodChannel?
  private let conversionQueue = DispatchQueue(
    label: "audio_core.plugin.convert",
    qos: .userInitiated
  )
  
  private var preparedAccessPaths = Set<String>()
  private let preparedAccessPathsLock = NSLock()

  public override init() {
    super.init()
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
    let messenger = registrar.messenger()
    #else
    let messenger = registrar.messenger
    #endif
    
    let channel = FlutterMethodChannel(
      name: "audio_core.player",
      binaryMessenger: messenger
    )
    let converterChannel = FlutterMethodChannel(
      name: "audio_core.audio_converter",
      binaryMessenger: messenger
    )
    let fftChannel = FlutterEventChannel(
      name: "audio_core.player/fft",
      binaryMessenger: messenger
    )
    
    let instance: AudioCorePlugin
    if let oldInstance = shared {
      debugPrint("[AudioCorePlugin] register: Hot restart detected. Reusing existing plugin instance \(Unmanaged.passUnretained(oldInstance).toOpaque()).")
      oldInstance.softCleanup()
      instance = oldInstance
    } else {
      let newInstance = AudioCorePlugin()
      debugPrint("[AudioCorePlugin] register: Created new plugin instance \(Unmanaged.passUnretained(newInstance).toOpaque()).")
      instance = newInstance
      shared = instance
    }
    
    instance.channel = channel
    instance.converterChannel = converterChannel
    registrar.addMethodCallDelegate(instance, channel: channel)
    registrar.addMethodCallDelegate(instance, channel: converterChannel)
    fftChannel.setStreamHandler(instance)
    debugPrint("[AudioCorePlugin] register: Completed registration for instance \(Unmanaged.passUnretained(instance).toOpaque()).")
  }

  private func normalizedFilePath(_ path: String) -> String {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("file://"), let url = URL(string: trimmed) {
      return url.standardizedFileURL.resolvingSymlinksInPath().path
    }
    return URL(fileURLWithPath: trimmed).standardizedFileURL.resolvingSymlinksInPath().path
  }

  private func prepareForFileWrite(path: String) throws {
    let normalized = normalizedFilePath(path)
    preparedAccessPathsLock.lock()
    defer { preparedAccessPathsLock.unlock() }
    if !preparedAccessPaths.contains(normalized) {
      _ = try fileAccess.acquireAccess(for: normalized)
      preparedAccessPaths.insert(normalized)
    }
  }

  private func finishFileWrite(path: String) {
    let normalized = normalizedFilePath(path)
    preparedAccessPathsLock.lock()
    defer { preparedAccessPathsLock.unlock() }
    if preparedAccessPaths.contains(normalized) {
      fileAccess.releaseAccess(for: normalized)
      preparedAccessPaths.remove(normalized)
    }
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "sayHello":
      result(nil)

    case "prepareForFileWrite":
      do {
        if let paths = Self.readStringArray(call.arguments, key: "paths"), !paths.isEmpty {
          for path in paths {
            try prepareForFileWrite(path: path)
          }
        } else if let path = Self.readString(call.arguments, key: "path") {
          try prepareForFileWrite(path: path)
        }
        result(nil)
      } catch {
        result(FlutterError(
          code: "PREPARE_FILE_WRITE_FAILED",
          message: error.localizedDescription,
          details: nil
        ))
      }

    case "finishFileWrite":
      if let paths = Self.readStringArray(call.arguments, key: "paths"), !paths.isEmpty {
        for path in paths {
          finishFileWrite(path: path)
        }
      } else if let path = Self.readString(call.arguments, key: "path") {
        finishFileWrite(path: path)
      }
      result(nil)

    case "getCapabilities":
      result(AppleAudioTranscoder.capabilities())

    case "convertFile":
      guard let args = call.arguments as? [String: Any] else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "Arguments are null", details: nil))
        return
      }
      conversionQueue.async {
        let payload = AppleAudioTranscoder.convert(request: args)
        DispatchQueue.main.async {
          result(payload)
        }
      }

    case "registerPersistentAccess":
      guard let path = Self.readString(call.arguments, key: "path") else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "Path is null", details: nil))
        return
      }
      result(fileAccess.registerPersistentAccess(for: path))

    case "forgetPersistentAccess":
      guard let path = Self.readString(call.arguments, key: "path") else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "Path is null", details: nil))
        return
      }
      fileAccess.forgetPersistentAccess(for: path)
      result(nil)

    case "hasPersistentAccess":
      guard let path = Self.readString(call.arguments, key: "path") else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "Path is null", details: nil))
        return
      }
      result(fileAccess.hasPersistentAccess(for: path))

    case "listPersistentAccessPaths":
      result(fileAccess.listPersistentAccessPaths())

    case "beginScopedAccess":
      guard let path = Self.readString(call.arguments, key: "path") else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "Path is null", details: nil))
        return
      }
      do {
        _ = try fileAccess.acquireAccess(for: path)
        result(true)
      } catch {
        result(false)
      }

    case "endScopedAccess":
      guard let path = Self.readString(call.arguments, key: "path") else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "Path is null", details: nil))
        return
      }
      fileAccess.releaseAccess(for: path)
      result(nil)

    case "dispose":
      result(nil)

    case "logMessage":
      let message = Self.readString(call.arguments, key: "message") ?? ""
      let level = Self.readString(call.arguments, key: "level") ?? "info"
      self.logMessage(level: level, message: message)
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  public func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    return nil
  }

  deinit {
    debugPrint("[AudioCorePlugin] deinit for instance \(Unmanaged.passUnretained(self).toOpaque())")
    cleanup()
  }

  private func cleanup() {
    debugPrint("[AudioCorePlugin] cleanup called for instance \(Unmanaged.passUnretained(self).toOpaque())")
    preparedAccessPathsLock.lock()
    for path in preparedAccessPaths {
      fileAccess.releaseAccess(for: path)
    }
    preparedAccessPaths.removeAll()
    preparedAccessPathsLock.unlock()
    fileAccess.releaseAllAccess()
    channel = nil
    converterChannel = nil
  }

  private func softCleanup() {
    debugPrint("[AudioCorePlugin] softCleanup called for instance \(Unmanaged.passUnretained(self).toOpaque())")
    preparedAccessPathsLock.lock()
    for path in preparedAccessPaths {
      fileAccess.releaseAccess(for: path)
    }
    preparedAccessPaths.removeAll()
    preparedAccessPathsLock.unlock()
    fileAccess.releaseAllAccess()
    channel = nil
    converterChannel = nil
  }

  private func logMessage(level: String, message: String) {
    switch level.lowercased() {
    case "debug":
      debugPrint("[AudioCorePlugin] \(message)")
    case "warning":
      debugPrint("[AudioCorePlugin][warning] \(message)")
    case "error":
      debugPrint("[AudioCorePlugin][error] \(message)")
    default:
      debugPrint("[AudioCorePlugin] \(message)")
    }
  }

  private static func readString(_ arguments: Any?, key: String) -> String? {
    guard let args = arguments as? [String: Any] else { return nil }
    return args[key] as? String
  }

  private static func readStringArray(_ arguments: Any?, key: String) -> [String]? {
    guard let args = arguments as? [String: Any] else { return nil }
    guard let values = args[key] as? [Any] else { return nil }
    let strings = values.compactMap { $0 as? String }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    return strings.isEmpty ? nil : strings
  }
}
