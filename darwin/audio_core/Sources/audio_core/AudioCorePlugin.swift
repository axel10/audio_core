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
  private var pendingPickerResult: FlutterResult?
  private let conversionQueue = DispatchQueue(
    label: "audio_core.plugin.convert",
    qos: .userInitiated
  )
  
  private var preparedAccessPaths = Set<String>()
  private let preparedAccessPathsLock = NSLock()

  /// 冷启动时文档打开可能早于插件注册完成，先攒在这里等 Dart 拉取。
  private static var pendingOpenedPaths: [String] = []
  private static let pendingOpenedPathsLock = NSLock()

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
    #if os(iOS)
    // 文档打开走的是 UIScene 生命周期（`scene(_:openURLContexts:)`），
    // Flutter 的插件生命周期委托只转发 openURL（自定义 scheme），
    // 所以必须额外注册为 scene 委托，否则「文件 app → 用 Vynody 打开」无人接收。
    if #available(iOS 13.0, *) {
      registrar.addSceneDelegate(instance)
    }
    #endif
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

    case "pickAndAuthorizeDirectory":
      #if os(iOS)
      self.pendingPickerResult = result
      let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
      picker.delegate = self
      picker.allowsMultipleSelection = false
      var topVC: UIViewController?
      if let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
         let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first {
        topVC = window.rootViewController
      } else if let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow }) ?? UIApplication.shared.windows.first {
        topVC = window.rootViewController
      }
      while let presented = topVC?.presentedViewController {
        topVC = presented
      }
      if let topVC = topVC {
        topVC.present(picker, animated: true)
      } else {
        result(FlutterError(code: "NO_VIEW_CONTROLLER", message: "Failed to find key window root view controller", details: nil))
        self.pendingPickerResult = nil
      }
      #else
      result(nil)
      #endif

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

    case "getPendingOpenedFiles":
      // 冷启动阶段由 scene 回调攒下的外部打开路径，Dart 就绪后主动拉取。
      result(Self.drainPendingOpenedPaths())

    case "beginScopedAccess":
      guard let path = Self.readString(call.arguments, key: "path") else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "Path is null", details: nil))
        return
      }
      // Report the real scope state. Returning `true` unconditionally made the
      // Dart side believe a root path was authorized while every directory
      // listing was actually rejected with EPERM.
      result(fileAccess.beginScopedAccess(
        for: path,
        holder: Self.readAccessHolder(call.arguments)
      ))

    case "endScopedAccess":
      guard let path = Self.readString(call.arguments, key: "path") else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "Path is null", details: nil))
        return
      }
      fileAccess.releaseAccess(
        for: path,
        holder: Self.readAccessHolder(call.arguments)
      )
      result(nil)

    case "getDirectoryDisplayName":
      guard let path = Self.readString(call.arguments, key: "path") else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "Path is null", details: nil))
        return
      }
      result(Self.resolveDisplayName(forPath: path))

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
    // 热重启只回收「文件写入锁」这类内核自己发起的临时授权。
    // 不要调用 releaseAllAccess()：用户授予的曲库 root / 分享目录 / 播放曲目
    // 属于应用级授权，必须活得比插件实例久，否则每次热重启后曲库都变成 0 首。
    preparedAccessPathsLock.lock()
    for path in preparedAccessPaths {
      fileAccess.releaseAccess(for: path)
    }
    preparedAccessPaths.removeAll()
    preparedAccessPathsLock.unlock()
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

  /// 读取 `beginScopedAccess` / `endScopedAccess` 的持有者标识。
  ///
  /// 缺省走 coordinator 的 default holder，保证旧调用方（示例页、写入锁）
  /// 各自成对时仍然闭合。
  private static func readAccessHolder(_ arguments: Any?) -> String {
    let holder = readString(arguments, key: "holder")?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let holder, !holder.isEmpty else {
      return SecurityScopedFileAccessCoordinator.defaultAccessHolder
    }
    return holder
  }

  private static func readStringArray(_ arguments: Any?, key: String) -> [String]? {
    guard let args = arguments as? [String: Any] else { return nil }
    guard let values = args[key] as? [Any] else { return nil }
    let strings = values.compactMap { $0 as? String }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    return strings.isEmpty ? nil : strings
  }

  /// Returns whether the directory at [path] can actually be opened for
  /// listing. Uses `opendir` so probing a huge folder stays O(1).
  static func isDirectoryReadable(path: String) -> Bool {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
          isDirectory.boolValue else {
      return false
    }
    guard let handle = opendir(path) else {
      return false
    }
    closedir(handle)
    return true
  }

  public static func resolveDisplayName(forPath path: String) -> String? {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let url: URL
    if trimmed.hasPrefix("file://"), let parsed = URL(string: trimmed) {
      url = parsed
    } else {
      url = URL(fileURLWithPath: trimmed)
    }
    return resolveDisplayName(for: url)
  }

  public static func resolveDisplayName(for url: URL) -> String? {
    let standardized = url.standardizedFileURL.resolvingSymlinksInPath()

    // 1. Try URL localizedNameKey
    if let resourceValues = try? standardized.resourceValues(forKeys: [.localizedNameKey]),
       let localizedName = resourceValues.localizedName,
       !localizedName.isEmpty,
       localizedName != "Documents" && localizedName != "Document" {
      return localizedName
    }

    // 2. Try FileManager displayName
    let fmDisplayName = FileManager.default.displayName(atPath: standardized.path)
    if !fmDisplayName.isEmpty && fmDisplayName != "Documents" && fmDisplayName != "Document" && fmDisplayName != standardized.lastPathComponent {
      return fmDisplayName
    }

    // 3. Check if this is an iOS App Documents directory
    let path = standardized.path
    if path.hasSuffix("/Documents") || path.hasSuffix("/Document") || standardized.lastPathComponent == "Documents" {
      #if os(iOS)
      // Check if it's the current app's own Documents directory
      if let appDocPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.standardizedFileURL.resolvingSymlinksInPath().path {
        if path == appDocPath || url.standardizedFileURL.path == appDocPath {
          let appName = Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String
            ?? Bundle.main.infoDictionary?["CFBundleName"] as? String
            ?? "Vynody"
          return appName
        }
      }

      // Check Application container metadata plist:
      // Pattern: /var/mobile/Containers/Data/Application/<UUID>/Documents
      let parentURL = standardized.deletingLastPathComponent()
      let metadataPlistURL = parentURL.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
      if let data = try? Data(contentsOf: metadataPlistURL),
         let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
        if let bundleId = plist["MCMMetadataIdentifier"] as? String, !bundleId.isEmpty {
          return formatBundleIdentifier(bundleId)
        }
      }

      // Check Shared AppGroup:
      // Pattern: /var/mobile/Containers/Shared/AppGroup/<UUID_or_GroupID>/
      if path.contains("Containers/Shared/AppGroup") {
        let components = path.components(separatedBy: "/")
        if let groupIndex = components.firstIndex(of: "AppGroup"), groupIndex + 1 < components.count {
          let groupId = components[groupIndex + 1]
          let metadataURL = URL(fileURLWithPath: "/" + components[1...groupIndex + 1].joined(separator: "/")).appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
          if let data = try? Data(contentsOf: metadataURL),
             let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
             let bundleId = plist["MCMMetadataIdentifier"] as? String, !bundleId.isEmpty {
            return formatBundleIdentifier(bundleId)
          }
          return formatBundleIdentifier(groupId)
        }
      }
      #endif
    }

    return nil
  }

  private static func formatBundleIdentifier(_ bundleId: String) -> String {
    var id = bundleId
    if id.hasPrefix("group.") {
      id = String(id.dropFirst(6))
    }
    var parts = id.components(separatedBy: ".").filter { !$0.isEmpty }
    if parts.count > 1 {
      var last = parts.removeLast()
      if (last.lowercased() == "ios" || last.lowercased() == "app") && !parts.isEmpty {
        last = parts.removeLast()
      }
      if last.lowercased().hasSuffix("-ios") {
        last = String(last.dropLast(4))
      } else if last.lowercased().hasSuffix("_ios") {
        last = String(last.dropLast(4))
      }
      if !last.isEmpty {
        return last
      }
    }
    return bundleId
  }

  // MARK: - 外部打开（供 scene 委托使用）

  fileprivate static func appendPendingOpenedPaths(_ paths: [String]) {
    guard !paths.isEmpty else { return }
    pendingOpenedPathsLock.lock()
    pendingOpenedPaths.append(contentsOf: paths)
    pendingOpenedPathsLock.unlock()
  }

  fileprivate static func drainPendingOpenedPaths() -> [String] {
    pendingOpenedPathsLock.lock()
    defer { pendingOpenedPathsLock.unlock() }
    let paths = pendingOpenedPaths
    pendingOpenedPaths.removeAll()
    return paths
  }

  /// 把已拿到授权的外部路径推给 Dart；通道尚未建好时先攒着等 Dart 拉取。
  fileprivate func notifyOpenedPaths(_ paths: [String]) {
    guard !paths.isEmpty else { return }
    guard let channel else {
      Self.appendPendingOpenedPaths(paths)
      return
    }
    channel.invokeMethod("onOpenFiles", arguments: paths)
  }
}

#if os(iOS)
@available(iOS 13.0, *)
extension AudioCorePlugin: FlutterSceneLifeCycleDelegate {
  /// 文档「打开方式 → Vynody」的入口。
  ///
  /// 必须在回调内用**原始 URL** 打开 scope 并落 bookmark：security scope 只挂在
  /// 这个 URL 对象上，一旦标准化或降级成路径字符串就再也拿不回来。回调返回后
  /// 这个 URL 即失效，所以授权动作不能推迟到 Dart 侧再做。
  public func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) -> Bool {
    var paths: [String] = []
    for context in URLContexts {
      let url = context.url
      guard url.isFileURL else { continue }
      _ = fileAccess.acquireAccess(for: url)
      _ = fileAccess.registerPersistentAccess(for: url)
      paths.append(url.path)
    }
    notifyOpenedPaths(paths)
    return !paths.isEmpty
  }
}
#endif

#if os(iOS)
extension AudioCorePlugin: UIDocumentPickerDelegate {
  public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let url = urls.first else {
      pendingPickerResult?(nil)
      pendingPickerResult = nil
      return
    }

    // The security scope lives only in this exact URL object. Standardizing it
    // (`standardizedFileURL` / `resolvingSymlinksInPath()`) before calling
    // `startAccessingSecurityScopedResource()` silently kills the grant, and
    // every later directory listing fails with EPERM. Start and persist the
    // bookmark from the original URL first, then derive the path string.
    _ = fileAccess.acquireAccess(for: url)
    _ = fileAccess.registerPersistentAccess(for: url)

    let path = url.standardizedFileURL.resolvingSymlinksInPath().path

    // Verify instead of assuming: a picked directory we cannot list would show
    // up in the library as "0 songs" with no explanation.
    guard Self.isDirectoryReadable(path: path) else {
      debugPrint("[AudioCorePlugin] picked directory is not readable: \(path)")
      pendingPickerResult?(FlutterError(
        code: "DIRECTORY_ACCESS_DENIED",
        message: path,
        details: nil
      ))
      pendingPickerResult = nil
      return
    }

    pendingPickerResult?(path)
    pendingPickerResult = nil
  }

  public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    pendingPickerResult?(nil)
    pendingPickerResult = nil
  }
}
#endif
