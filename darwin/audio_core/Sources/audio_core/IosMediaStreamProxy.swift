#if os(iOS)
import AVFoundation
import CoreMedia
import Foundation
import Network

/// Lightweight loopback HTTP server (`127.0.0.1`) that streams `ipod-library://`
/// assets on demand as 16-bit PCM WAV using `AVAssetReader`, supporting HTTP
/// `Range` requests for instant seeking without writing temporary files to disk.
final class IosMediaStreamProxy {
  static let shared = IosMediaStreamProxy()

  private let lock = NSLock()
  private let serverQueue = DispatchQueue(label: "audio_core.ios_media_proxy.server", qos: .userInitiated)
  private let streamQueue = DispatchQueue(
    label: "audio_core.ios_media_proxy.stream",
    qos: .userInitiated,
    attributes: .concurrent
  )

  private var listener: NWListener?
  private var port: UInt16?
  private var tokenToAssetURL: [String: URL] = [:]
  private var assetURLToToken: [String: String] = [:]

  private init() {}

  func resolveStreamURL(for assetURLString: String, completion: @escaping (Result<String, Error>) -> Void) {
    guard let assetURL = URL(string: assetURLString), assetURL.scheme == "ipod-library" else {
      completion(.failure(NSError(
        domain: "IosMediaStreamProxy",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: "Invalid ipod-library URL: \(assetURLString)"]
      )))
      return
    }

    let token = registerToken(for: assetURL)
    ensureServerStarted { [weak self] result in
      switch result {
      case .success(let port):
        let streamUrl = "http://127.0.0.1:\(port)/track/\(token).wav"
        completion(.success(streamUrl))
      case .failure(let error):
        completion(.failure(error))
      }
      _ = self
    }
  }

  private func registerToken(for assetURL: URL) -> String {
    lock.lock()
    defer { lock.unlock() }
    let key = assetURL.absoluteString
    if let existing = assetURLToToken[key] {
      return existing
    }
    let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    assetURLToToken[key] = token
    tokenToAssetURL[token] = assetURL
    return token
  }

  private func assetURL(forToken token: String) -> URL? {
    lock.lock()
    defer { lock.unlock() }
    return tokenToAssetURL[token]
  }

  private func ensureServerStarted(completion: @escaping (Result<UInt16, Error>) -> Void) {
    lock.lock()
    if let port = self.port, self.listener?.state == .ready {
      lock.unlock()
      completion(.success(port))
      return
    }
    lock.unlock()

    serverQueue.async { [weak self] in
      guard let self = self else { return }
      self.lock.lock()
      if let port = self.port, self.listener?.state == .ready {
        self.lock.unlock()
        completion(.success(port))
        return
      }

      self.listener?.cancel()
      self.listener = nil
      self.port = nil

      do {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .loopback
        let listener = try NWListener(using: params, on: .any)
        var completed = false

        listener.stateUpdateHandler = { [weak self] state in
          guard let self = self else { return }
          switch state {
          case .ready:
            if let boundPort = listener.port?.rawValue {
              self.lock.lock()
              self.port = boundPort
              self.lock.unlock()
              if !completed {
                completed = true
                completion(.success(boundPort))
              }
            }
          case .failed(let error):
            self.lock.lock()
            if self.listener === listener {
              self.listener = nil
              self.port = nil
            }
            self.lock.unlock()
            if !completed {
              completed = true
              completion(.failure(error))
            }
          case .cancelled:
            if !completed {
              completed = true
              completion(.failure(NSError(
                domain: "IosMediaStreamProxy",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Proxy listener cancelled"]
              )))
            }
          default:
            break
          }
        }

        listener.newConnectionHandler = { [weak self] connection in
          self?.handleConnection(connection)
        }

        self.listener = listener
        self.lock.unlock()
        listener.start(queue: self.serverQueue)
      } catch {
        self.lock.unlock()
        completion(.failure(error))
      }
    }
  }

  private func handleConnection(_ connection: NWConnection) {
    connection.start(queue: streamQueue)
    receiveHTTPRequest(on: connection, buffer: Data())
  }

  private func receiveHTTPRequest(on connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
      guard let self = self else { return }
      if let error = error {
        debugPrint("[IosMediaStreamProxy] receive error: \(error)")
        connection.cancel()
        return
      }

      var currentBuffer = buffer
      if let data = data {
        currentBuffer.append(data)
      }

      if let headerEndRange = currentBuffer.range(of: Data("\r\n\r\n".utf8)) {
        let headerData = currentBuffer.subdata(in: 0..<headerEndRange.lowerBound)
        if let headerText = String(data: headerData, encoding: .utf8) {
          self.processHTTPRequest(headerText, on: connection)
        } else {
          self.sendErrorResponse(status: "400 Bad Request", on: connection)
        }
        return
      }

      if isComplete || currentBuffer.count > 64 * 1024 {
        self.sendErrorResponse(status: "400 Bad Request", on: connection)
        return
      }

      self.receiveHTTPRequest(on: connection, buffer: currentBuffer)
    }
  }

  private func processHTTPRequest(_ headerText: String, on connection: NWConnection) {
    let lines = headerText.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else {
      sendErrorResponse(status: "400 Bad Request", on: connection)
      return
    }

    let parts = requestLine.split(separator: " ")
    guard parts.count >= 2 else {
      sendErrorResponse(status: "400 Bad Request", on: connection)
      return
    }

    let method = String(parts[0]).uppercased()
    let rawPath = String(parts[1])
    guard method == "GET" || method == "HEAD" else {
      sendErrorResponse(status: "405 Method Not Allowed", on: connection)
      return
    }

    // Expected path: /track/<token>.wav
    let pathOnly = rawPath.split(separator: "?").first.map(String.init) ?? rawPath
    guard pathOnly.hasPrefix("/track/") else {
      sendErrorResponse(status: "404 Not Found", on: connection)
      return
    }
    var token = String(pathOnly.dropFirst("/track/".count))
    if token.hasSuffix(".wav") {
      token = String(token.dropLast(4))
    }

    guard let assetURL = assetURL(forToken: token) else {
      sendErrorResponse(status: "404 Not Found", on: connection)
      return
    }

    var rangeHeader: String?
    for line in lines.dropFirst() {
      if let colonIdx = line.firstIndex(of: ":") {
        let name = line[..<colonIdx].trimmingCharacters(in: .whitespaces).lowercased()
        if name == "range" {
          rangeHeader = line[line.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)
          break
        }
      }
    }

    streamAsset(
      assetURL: assetURL,
      method: method,
      rangeHeader: rangeHeader,
      on: connection
    )
  }

  private struct AudioFormatInfo {
    let sampleRate: Int
    let channels: Int
    let totalPcmBytes: Int64
    var totalFileBytes: Int64 { 44 + totalPcmBytes }
    var bytesPerFrame: Int64 { Int64(channels * 2) }
  }

  private func inspectAudioFormat(asset: AVURLAsset) throws -> (AVAssetTrack, AudioFormatInfo) {
    let tracks = asset.tracks(withMediaType: .audio)
    guard let track = tracks.first else {
      throw NSError(
        domain: "IosMediaStreamProxy",
        code: -3,
        userInfo: [NSLocalizedDescriptionKey: "No audio track found in asset"]
      )
    }

    var sampleRate = 44100
    var channels = 2

    if let formatDescs = track.formatDescriptions as? [CMFormatDescription],
       let firstDesc = formatDescs.first,
       let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(firstDesc)?.pointee {
      if asbd.mSampleRate > 0 {
        sampleRate = Int(asbd.mSampleRate.rounded())
      }
      if asbd.mChannelsPerFrame > 0 {
        channels = min(Int(asbd.mChannelsPerFrame), 2)
      }
    }

    let durationSeconds = max(0.0, CMTimeGetSeconds(asset.duration))
    let totalFrames = max(0, Int64((durationSeconds * Double(sampleRate)).rounded()))
    let bytesPerFrame = Int64(channels * 2)
    let totalPcmBytes = totalFrames * bytesPerFrame

    return (track, AudioFormatInfo(
      sampleRate: sampleRate,
      channels: channels,
      totalPcmBytes: totalPcmBytes
    ))
  }

  private func parseByteRange(_ header: String?, totalLength: Int64) -> (start: Int64, endInclusive: Int64)? {
    guard let header = header, header.lowercased().hasPrefix("bytes="), totalLength > 0 else {
      return nil
    }
    let spec = String(header.dropFirst("bytes=".count)).split(separator: ",").first.map(String.init) ?? ""
    let bounds = spec.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
    guard bounds.count == 2 else { return nil }

    if bounds[0].isEmpty {
      // Suffix byte range: bytes=-500
      guard let suffixLen = Int64(bounds[1]), suffixLen > 0 else { return nil }
      let start = max(0, totalLength - suffixLen)
      return (start, totalLength - 1)
    }

    guard let start = Int64(bounds[0]), start >= 0, start < totalLength else {
      return nil
    }
    let endInclusive: Int64
    if bounds[1].isEmpty {
      endInclusive = totalLength - 1
    } else if let parsedEnd = Int64(bounds[1]) {
      endInclusive = min(parsedEnd, totalLength - 1)
    } else {
      return nil
    }

    guard start <= endInclusive else { return nil }
    return (start, endInclusive)
  }

  private func buildWavHeader(sampleRate: Int, channels: Int, pcmDataBytes: Int64) -> Data {
    let clampedDataSize = UInt32(min(max(pcmDataBytes, 0), Int64(UInt32.max - 36)))
    let riffSize = clampedDataSize &+ 36
    let byteRate = UInt32(sampleRate * channels * 2)
    let blockAlign = UInt16(channels * 2)
    let bitsPerSample: UInt16 = 16

    var header = Data(capacity: 44)
    header.append(contentsOf: "RIFF".utf8)
    header.appendLittleEndian(riffSize)
    header.append(contentsOf: "WAVE".utf8)
    header.append(contentsOf: "fmt ".utf8)
    header.appendLittleEndian(UInt32(16)) // PCM fmt chunk size
    header.appendLittleEndian(UInt16(1))  // PCM audio format
    header.appendLittleEndian(UInt16(channels))
    header.appendLittleEndian(UInt32(sampleRate))
    header.appendLittleEndian(byteRate)
    header.appendLittleEndian(blockAlign)
    header.appendLittleEndian(bitsPerSample)
    header.append(contentsOf: "data".utf8)
    header.appendLittleEndian(clampedDataSize)
    return header
  }

  private func streamAsset(
    assetURL: URL,
    method: String,
    rangeHeader: String?,
    on connection: NWConnection
  ) {
    let asset = AVURLAsset(url: assetURL)
    let track: AVAssetTrack
    let formatInfo: AudioFormatInfo
    do {
      (track, formatInfo) = try inspectAudioFormat(asset: asset)
    } catch {
      debugPrint("[IosMediaStreamProxy] Failed to inspect asset \(assetURL): \(error)")
      sendErrorResponse(status: "500 Internal Server Error", on: connection)
      return
    }

    let totalLength = formatInfo.totalFileBytes
    let isRangeRequest = rangeHeader != nil
    let byteRange: (start: Int64, endInclusive: Int64)
    if let parsed = parseByteRange(rangeHeader, totalLength: totalLength) {
      byteRange = parsed
    } else if isRangeRequest {
      sendRangeNotSatisfiable(totalLength: totalLength, on: connection)
      return
    } else {
      byteRange = (0, max(0, totalLength - 1))
    }

    let contentLength = totalLength > 0 ? (byteRange.endInclusive - byteRange.start + 1) : 0
    var responseHeader = isRangeRequest
      ? "HTTP/1.1 206 Partial Content\r\n"
      : "HTTP/1.1 200 OK\r\n"
    responseHeader += "Content-Type: audio/wav\r\n"
    responseHeader += "Accept-Ranges: bytes\r\n"
    responseHeader += "Content-Length: \(contentLength)\r\n"
    if isRangeRequest {
      responseHeader += "Content-Range: bytes \(byteRange.start)-\(byteRange.endInclusive)/\(totalLength)\r\n"
    }
    responseHeader += "Connection: close\r\n\r\n"

    let headerData = Data(responseHeader.utf8)

    if method == "HEAD" || contentLength == 0 {
      connection.send(content: headerData, completion: .contentProcessed { _ in
        connection.cancel()
      })
      return
    }

    var cancelled = false
    connection.stateUpdateHandler = { state in
      switch state {
      case .cancelled, .failed:
        cancelled = true
      default:
        break
      }
    }

    // Send HTTP response headers first.
    guard sendSync(data: headerData, on: connection) else {
      connection.cancel()
      return
    }

    var currentOffset = byteRange.start
    let endExclusive = byteRange.endInclusive + 1

    // 1. Send WAV header slice if requested range overlaps [0, 44).
    if currentOffset < 44 {
      let wavHeader = buildWavHeader(
        sampleRate: formatInfo.sampleRate,
        channels: formatInfo.channels,
        pcmDataBytes: formatInfo.totalPcmBytes
      )
      let sliceStart = Int(currentOffset)
      let sliceEnd = Int(min(44, endExclusive))
      let headerSlice = wavHeader.subdata(in: sliceStart..<sliceEnd)
      if !sendSync(data: headerSlice, on: connection) {
        connection.cancel()
        return
      }
      currentOffset = Int64(sliceEnd)
    }

    if currentOffset >= endExclusive || cancelled {
      connection.cancel()
      return
    }

    // 2. Stream PCM frames from AVAssetReader starting at the requested byte offset.
    let pcmOffset = currentOffset - 44
    let bytesPerFrame = formatInfo.bytesPerFrame
    let startFrame = pcmOffset / bytesPerFrame
    var skipInitialBytes = Int(pcmOffset % bytesPerFrame)

    let reader: AVAssetReader
    do {
      reader = try AVAssetReader(asset: asset)
    } catch {
      debugPrint("[IosMediaStreamProxy] AVAssetReader init failed: \(error)")
      connection.cancel()
      return
    }

    let outputSettings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: formatInfo.sampleRate,
      AVNumberOfChannelsKey: formatInfo.channels,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
    output.alwaysCopiesSampleData = false

    guard reader.canAdd(output) else {
      connection.cancel()
      return
    }
    reader.add(output)

    if startFrame > 0 {
      let startTime = CMTime(value: startFrame, timescale: CMTimeScale(formatInfo.sampleRate))
      reader.timeRange = CMTimeRange(start: startTime, duration: .positiveInfinity)
    }

    guard reader.startReading() else {
      debugPrint("[IosMediaStreamProxy] AVAssetReader startReading failed: \(String(describing: reader.error))")
      connection.cancel()
      return
    }

    while !cancelled && currentOffset < endExclusive && reader.status == .reading {
      guard let sampleBuffer = output.copyNextSampleBuffer() else {
        break
      }
      guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
        continue
      }

      var totalBlockLen = 0
      var dataPointer: UnsafeMutablePointer<Int8>?
      let status = CMBlockBufferGetDataPointer(
        blockBuffer,
        atOffset: 0,
        lengthAtOffsetOut: nil,
        totalLengthOut: &totalBlockLen,
        dataPointerOut: &dataPointer
      )
      guard status == kCMBlockBufferNoErr, let ptr = dataPointer, totalBlockLen > 0 else {
        continue
      }

      var offsetInBlock = 0
      if skipInitialBytes > 0 {
        if skipInitialBytes >= totalBlockLen {
          skipInitialBytes -= totalBlockLen
          continue
        }
        offsetInBlock = skipInitialBytes
        skipInitialBytes = 0
      }

      let available = totalBlockLen - offsetInBlock
      let remainingNeeded = Int(min(Int64(available), endExclusive - currentOffset))
      if remainingNeeded <= 0 {
        break
      }

      let chunk = Data(bytes: ptr.advanced(by: offsetInBlock), count: remainingNeeded)
      if !sendSync(data: chunk, on: connection) {
        cancelled = true
        break
      }
      currentOffset += Int64(remainingNeeded)
    }

    reader.cancelReading()
    connection.cancel()
  }

  private func sendSync(data: Data, on connection: NWConnection) -> Bool {
    let semaphore = DispatchSemaphore(value: 0)
    var success = false
    connection.send(content: data, completion: .contentProcessed { error in
      success = (error == nil)
      semaphore.signal()
    })
    semaphore.wait()
    return success
  }

  private func sendErrorResponse(status: String, on connection: NWConnection) {
    let response = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
      connection.cancel()
    })
  }

  private func sendRangeNotSatisfiable(totalLength: Int64, on connection: NWConnection) {
    let response = "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(totalLength)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
      connection.cancel()
    })
  }
}

private extension Data {
  mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
    var little = value.littleEndian
    Swift.withUnsafeBytes(of: &little) { bytes in
      append(contentsOf: bytes)
    }
  }
}
#endif
