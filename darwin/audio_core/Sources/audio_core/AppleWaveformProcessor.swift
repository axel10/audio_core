import AVFoundation
import Foundation

import SFBAudioEngine

enum AppleWaveformProcessor {
  private static let waveformRmsWindowsPerChunk = 8
  private static let waveformPrecisionScale = 100.0

  static func decodeWaveform(url: URL, expectedChunks: Int, sampleStride: Int) throws -> [Double] {
    let decoder = try AudioDecoder(url: url, detectContentType: true)
    defer { _ = try? decoder.close() }

    _ = try decoder.open()
    let sourceFormat = decoder.processingFormat
    let processingDescription = sourceFormat.streamDescription.pointee
    debugPrint(
      "[AppleAudioEngine] waveform decode start path=\(url.lastPathComponent) " +
      "sampleRate=\(String(format: "%.1f", sourceFormat.sampleRate)) " +
      "channels=\(sourceFormat.channelCount) " +
      "commonFormat=\(sourceFormat.commonFormat.rawValue) " +
      "interleaved=\(sourceFormat.isInterleaved) " +
      "formatID=\(processingDescription.mFormatID) " +
      "formatFlags=\(processingDescription.mFormatFlags) " +
      "bitsPerChannel=\(processingDescription.mBitsPerChannel) " +
      "bytesPerFrame=\(processingDescription.mBytesPerFrame) " +
      "bytesPerPacket=\(processingDescription.mBytesPerPacket) " +
      "framesPerPacket=\(processingDescription.mFramesPerPacket)"
    )

    let totalFrames = decoder.length
    let supportsSeeking = decoder.supportsSeeking

    if supportsSeeking && totalFrames > 0 {
      let stride = max(1, sampleStride)
      let baseWindowSize = max(512, 8192 / stride)
      debugPrint("[AppleAudioEngine] Using step/stride sampling. totalFrames=\(totalFrames) stride=\(stride) baseWindowSize=\(baseWindowSize)")
      let windowSize = min(AVAudioFrameCount(baseWindowSize), max(AVAudioFrameCount(512), AVAudioFrameCount(totalFrames / AVAudioFramePosition(expectedChunks))))
      let bufferCapacity = max(4096, windowSize)

      guard let sourceBuffer = AVAudioPCMBuffer(
        pcmFormat: sourceFormat,
        frameCapacity: bufferCapacity
      ) else {
        return Array(repeating: 0.0, count: expectedChunks)
      }
      guard let waveformFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sourceFormat.sampleRate,
        channels: sourceFormat.channelCount,
        interleaved: false
      ) else {
        return Array(repeating: 0.0, count: expectedChunks)
      }
      let convertedCapacity = max(bufferCapacity, AVAudioFrameCount(8192))
      guard let convertedBuffer = AVAudioPCMBuffer(
        pcmFormat: waveformFormat,
        frameCapacity: convertedCapacity
      ) else {
        return Array(repeating: 0.0, count: expectedChunks)
      }
      let converter = AVAudioConverter(from: sourceFormat, to: waveformFormat)

      var output = Array(repeating: 0.0, count: expectedChunks)
      let stepFrames = Double(totalFrames) / Double(expectedChunks)

      for chunk in 0..<expectedChunks {
        let targetFrame = AVAudioFramePosition(Double(chunk) * stepFrames)
        do {
          try decoder.seek(to: targetFrame)
          sourceBuffer.frameLength = 0
          try decoder.decode(into: sourceBuffer, length: windowSize)
          guard sourceBuffer.frameLength > 0 else {
            continue
          }

          let waveformBuffer: AVAudioPCMBuffer
          if let converter {
            convertedBuffer.frameLength = 0
            var converterConsumedSource = false
            var converterError: NSError?
            let status = converter.convert(to: convertedBuffer, error: &converterError) { _, outStatus in
              if converterConsumedSource {
                outStatus.pointee = .noDataNow
                return nil
              }
              converterConsumedSource = true
              outStatus.pointee = .haveData
              return sourceBuffer
            }
            if let converterError {
              debugPrint("[AppleAudioEngine] converter error for chunk \(chunk): \(converterError.localizedDescription)")
              continue
            }
            if status == .error {
              continue
            }
            waveformBuffer = convertedBuffer
          } else {
            waveformBuffer = sourceBuffer
          }

          var chunkMonoSamples: [Double] = []
          appendMonoSamples(from: waveformBuffer, into: &chunkMonoSamples)

          if !chunkMonoSamples.isEmpty {
            let rms = computeRms(samples: chunkMonoSamples, start: 0, end: chunkMonoSamples.count)
            output[chunk] = roundWaveformPrecision(max(0.0, min(rms, 1.0)))
          }
        } catch {
          debugPrint("[AppleAudioEngine] seek/decode failed for chunk \(chunk) at frame \(targetFrame): \(error.localizedDescription)")
        }
      }

      debugPrint("[AppleAudioEngine] Step/stride sampling complete. Output count = \(output.count)")
      return output
    }

    // Fallback: full linear decoding
    debugPrint("[AppleAudioEngine] Step/stride sampling not supported or length is invalid. Falling back to full decoding.")
    let bufferCapacity: AVAudioFrameCount = 4096
    guard let sourceBuffer = AVAudioPCMBuffer(
      pcmFormat: sourceFormat,
      frameCapacity: bufferCapacity
    ) else {
      return Array(repeating: 0.0, count: expectedChunks)
    }
    guard let waveformFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: sourceFormat.sampleRate,
      channels: sourceFormat.channelCount,
      interleaved: false
    ) else {
      return Array(repeating: 0.0, count: expectedChunks)
    }
    let convertedCapacity = max(bufferCapacity, AVAudioFrameCount(8192))
    guard let convertedBuffer = AVAudioPCMBuffer(
      pcmFormat: waveformFormat,
      frameCapacity: convertedCapacity
    ) else {
      return Array(repeating: 0.0, count: expectedChunks)
    }
    let converter = AVAudioConverter(from: sourceFormat, to: waveformFormat)

    var monoSamples: [Double] = []
    var decodeIteration = 0
    var loggedSourceBufferFormat = false
    var loggedConvertedBufferFormat = false
    var maxAbsSample = 0.0
    var minSample = Double.greatestFiniteMagnitude
    var maxSample = -Double.greatestFiniteMagnitude
    var nonZeroSampleCount = 0
    while true {
      try decoder.decode(into: sourceBuffer, length: bufferCapacity)
      guard sourceBuffer.frameLength > 0 else {
        break
      }
      decodeIteration += 1
      if !loggedSourceBufferFormat {
        let bufferDescription = sourceBuffer.format.streamDescription.pointee
        debugPrint(
          "[AppleAudioEngine] waveform first buffer format " +
          "frames=\(sourceBuffer.frameLength) " +
          "commonFormat=\(sourceBuffer.format.commonFormat.rawValue) " +
          "interleaved=\(sourceBuffer.format.isInterleaved) " +
          "channelCount=\(sourceBuffer.format.channelCount) " +
          "formatFlags=\(bufferDescription.mFormatFlags) " +
          "bitsPerChannel=\(bufferDescription.mBitsPerChannel) " +
          "bytesPerFrame=\(bufferDescription.mBytesPerFrame) " +
          "bytesPerPacket=\(bufferDescription.mBytesPerPacket)"
        )
        loggedSourceBufferFormat = true
      }

      let waveformBuffer: AVAudioPCMBuffer
      if let converter {
        convertedBuffer.frameLength = 0
        var converterConsumedSource = false
        var converterError: NSError?
        let status = converter.convert(to: convertedBuffer, error: &converterError) { _, outStatus in
          if converterConsumedSource {
            outStatus.pointee = .noDataNow
            return nil
          }
          converterConsumedSource = true
          outStatus.pointee = .haveData
          return sourceBuffer
        }
        if let converterError {
          throw converterError
        }
        if status == .error {
          throw NSError(
            domain: "audio_core.waveform",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Waveform PCM conversion failed"]
          )
        }
        waveformBuffer = convertedBuffer
      } else {
        waveformBuffer = sourceBuffer
      }

      if !loggedConvertedBufferFormat {
        let bufferDescription = waveformBuffer.format.streamDescription.pointee
        debugPrint(
          "[AppleAudioEngine] waveform working buffer format " +
          "frames=\(waveformBuffer.frameLength) " +
          "commonFormat=\(waveformBuffer.format.commonFormat.rawValue) " +
          "interleaved=\(waveformBuffer.format.isInterleaved) " +
          "channelCount=\(waveformBuffer.format.channelCount) " +
          "formatFlags=\(bufferDescription.mFormatFlags) " +
          "bitsPerChannel=\(bufferDescription.mBitsPerChannel) " +
          "bytesPerFrame=\(bufferDescription.mBytesPerFrame) " +
          "bytesPerPacket=\(bufferDescription.mBytesPerPacket)"
        )
        loggedConvertedBufferFormat = true
      }

      let startIndex = monoSamples.count
      appendMonoSamples(from: waveformBuffer, into: &monoSamples)
      let appendedCount = monoSamples.count - startIndex
      if appendedCount > 0 {
        var chunkMin = Double.greatestFiniteMagnitude
        var chunkMax = -Double.greatestFiniteMagnitude
        var chunkMaxAbs = 0.0
        var chunkNonZeroCount = 0
        let sliceEnd = min(monoSamples.count, startIndex + min(appendedCount, 8))
        let preview = monoSamples[startIndex..<sliceEnd].map {
          String(format: "%.6f", $0)
        }.joined(separator: ",")
        for index in startIndex..<monoSamples.count {
          let value = monoSamples[index]
          chunkMin = min(chunkMin, value)
          chunkMax = max(chunkMax, value)
          chunkMaxAbs = max(chunkMaxAbs, abs(value))
          if value != 0 {
            chunkNonZeroCount += 1
          }
        }
        minSample = min(minSample, chunkMin)
        maxSample = max(maxSample, chunkMax)
        maxAbsSample = max(maxAbsSample, chunkMaxAbs)
        nonZeroSampleCount += chunkNonZeroCount

        if decodeIteration <= 3 || chunkMaxAbs == 0 {
          debugPrint(
            "[AppleAudioEngine] waveform chunk #\(decodeIteration) " +
            "sourceFrames=\(sourceBuffer.frameLength) " +
            "workingFrames=\(waveformBuffer.frameLength) " +
            "appended=\(appendedCount) " +
            "min=\(String(format: "%.6f", chunkMin)) " +
            "max=\(String(format: "%.6f", chunkMax)) " +
            "maxAbs=\(String(format: "%.6f", chunkMaxAbs)) " +
            "nonZero=\(chunkNonZeroCount) " +
            "preview=[\(preview)]"
          )
        }
      } else {
        debugPrint(
          "[AppleAudioEngine] waveform chunk #\(decodeIteration) appended no mono samples " +
          "sourceFrames=\(sourceBuffer.frameLength) " +
          "workingFrames=\(waveformBuffer.frameLength)"
        )
      }
    }

    debugPrint(
      "[AppleAudioEngine] waveform decode complete monoSamples=\(monoSamples.count) " +
      "expectedChunks=\(expectedChunks) " +
      "min=\(String(format: "%.6f", minSample.isFinite ? minSample : 0.0)) " +
      "max=\(String(format: "%.6f", maxSample.isFinite ? maxSample : 0.0)) " +
      "maxAbs=\(String(format: "%.6f", maxAbsSample)) " +
      "nonZero=\(nonZeroSampleCount)"
    )

    return processWaveform(samples: monoSamples, expectedChunks: expectedChunks)
  }

  private static func appendMonoSamples(
    from buffer: AVAudioPCMBuffer,
    into monoSamples: inout [Double]
  ) {
    let frameLength = Int(buffer.frameLength)
    guard frameLength > 0 else { return }

    let channelCount = max(Int(buffer.format.channelCount), 1)
    let streamDescription = buffer.format.streamDescription.pointee
    let int16Scale = signedIntegerScale(
      bitsPerChannel: Int(streamDescription.mBitsPerChannel),
      fallbackBitsPerChannel: 16
    )
    let int32Scale = signedIntegerScale(
      bitsPerChannel: Int(streamDescription.mBitsPerChannel),
      fallbackBitsPerChannel: 32
    )

    if buffer.format.commonFormat == .pcmFormatFloat32 {
      if buffer.format.isInterleaved {
        guard let rawData = buffer.audioBufferList.pointee.mBuffers.mData else { return }
        let samples = rawData.assumingMemoryBound(to: Float.self)
        for frame in 0..<frameLength {
          var sum = 0.0
          let baseIndex = frame * channelCount
          for channel in 0..<channelCount {
            sum += Double(samples[baseIndex + channel])
          }
          monoSamples.append(sum / Double(channelCount))
        }
      } else if let channelData = buffer.floatChannelData {
        for frame in 0..<frameLength {
          var sum = 0.0
          for channel in 0..<channelCount {
            sum += Double(channelData[channel][frame])
          }
          monoSamples.append(sum / Double(channelCount))
        }
      }
      return
    }

    if buffer.format.commonFormat == .pcmFormatInt16 {
      if buffer.format.isInterleaved {
        guard let rawData = buffer.audioBufferList.pointee.mBuffers.mData else { return }
        let samples = rawData.assumingMemoryBound(to: Int16.self)
        for frame in 0..<frameLength {
          var sum = 0.0
          let baseIndex = frame * channelCount
          for channel in 0..<channelCount {
            sum += Double(samples[baseIndex + channel]) / int16Scale
          }
          monoSamples.append(sum / Double(channelCount))
        }
      } else if let channelData = buffer.int16ChannelData {
        for frame in 0..<frameLength {
          var sum = 0.0
          for channel in 0..<channelCount {
            sum += Double(channelData[channel][frame]) / int16Scale
          }
          monoSamples.append(sum / Double(channelCount))
        }
      }
      return
    }

    if buffer.format.commonFormat == .pcmFormatInt32 {
      if buffer.format.isInterleaved {
        guard let rawData = buffer.audioBufferList.pointee.mBuffers.mData else { return }
        let samples = rawData.assumingMemoryBound(to: Int32.self)
        for frame in 0..<frameLength {
          var sum = 0.0
          let baseIndex = frame * channelCount
          for channel in 0..<channelCount {
            sum += Double(samples[baseIndex + channel]) / int32Scale
          }
          monoSamples.append(sum / Double(channelCount))
        }
      } else if let channelData = buffer.int32ChannelData {
        for frame in 0..<frameLength {
          var sum = 0.0
          for channel in 0..<channelCount {
            sum += Double(channelData[channel][frame]) / int32Scale
          }
          monoSamples.append(sum / Double(channelCount))
        }
      }
      return
    }

    appendMonoSamplesFromUnknownPCM(from: buffer, into: &monoSamples)
  }

  private static func appendMonoSamplesFromUnknownPCM(
    from buffer: AVAudioPCMBuffer,
    into monoSamples: inout [Double]
  ) {
    let frameLength = Int(buffer.frameLength)
    guard frameLength > 0 else { return }

    let formatDescription = buffer.format.streamDescription.pointee

    let channelCount = max(Int(formatDescription.mChannelsPerFrame), 1)
    let bitsPerChannel = Int(formatDescription.mBitsPerChannel)
    let flags = formatDescription.mFormatFlags
    let isFloat = (flags & kAudioFormatFlagIsFloat) != 0
    let isSignedInteger = (flags & kAudioFormatFlagIsSignedInteger) != 0
    let isNonInterleaved = (flags & kAudioFormatFlagIsNonInterleaved) != 0
    let isBigEndian = (flags & kAudioFormatFlagIsBigEndian) != 0
    let isPacked = (flags & kAudioFormatFlagIsPacked) != 0
    let isAlignedHigh = (flags & kAudioFormatFlagIsAlignedHigh) != 0
    let bytesPerFrame = Int(formatDescription.mBytesPerFrame)
    let bytesPerChannel = max(1, bytesPerFrame / max(channelCount, 1))
    let int16Scale = signedIntegerScale(
      bitsPerChannel: bitsPerChannel,
      fallbackBitsPerChannel: 16
    )
    let int32Scale = signedIntegerScale(
      bitsPerChannel: bitsPerChannel,
      fallbackBitsPerChannel: 32
    )

    if isNonInterleaved {
      let audioBufferList = UnsafeMutablePointer(mutating: buffer.audioBufferList)
      let audioBuffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
      guard audioBuffers.count > 0 else {
        debugPrint(
          "[AppleAudioEngine] waveform decode empty noninterleaved buffer " +
          "commonFormat=\(buffer.format.commonFormat.rawValue) " +
          "bitsPerChannel=\(bitsPerChannel)"
        )
        return
      }

      if isFloat, bitsPerChannel == 32 {
        for frame in 0..<frameLength {
          var sum = 0.0
          for channelIndex in 0..<min(channelCount, audioBuffers.count) {
            guard let data = audioBuffers[channelIndex].mData else { return }
            let samples: UnsafeMutablePointer<Float> = data.assumingMemoryBound(to: Float.self)
            sum += Double(samples[frame])
          }
          monoSamples.append(sum / Double(channelCount))
        }
        return
      }

      if isFloat, bitsPerChannel == 64 {
        for frame in 0..<frameLength {
          var sum = 0.0
          for channelIndex in 0..<min(channelCount, audioBuffers.count) {
            guard let data = audioBuffers[channelIndex].mData else { return }
            let samples: UnsafeMutablePointer<Double> = data.assumingMemoryBound(to: Double.self)
            sum += samples[frame]
          }
          monoSamples.append(sum / Double(channelCount))
        }
        return
      }

      if isSignedInteger, bitsPerChannel == 16 {
        for frame in 0..<frameLength {
          var sum = 0.0
          for channelIndex in 0..<min(channelCount, audioBuffers.count) {
            guard let data = audioBuffers[channelIndex].mData else { return }
            let samples: UnsafeMutablePointer<Int16> = data.assumingMemoryBound(to: Int16.self)
            sum += Double(samples[frame]) / int16Scale
          }
          monoSamples.append(sum / Double(channelCount))
        }
        return
      }

      if isSignedInteger, bitsPerChannel == 32 {
        for frame in 0..<frameLength {
          var sum = 0.0
          for channelIndex in 0..<min(channelCount, audioBuffers.count) {
            guard let data = audioBuffers[channelIndex].mData else { return }
            let samples: UnsafeMutablePointer<Int32> = data.assumingMemoryBound(to: Int32.self)
            sum += Double(samples[frame]) / int32Scale
          }
          monoSamples.append(sum / Double(channelCount))
        }
        return
      }

      if isSignedInteger, bitsPerChannel == 24 {
        for frame in 0..<frameLength {
          var sum = 0.0
          let actualChannelCount = min(channelCount, audioBuffers.count)
          for channelIndex in 0..<actualChannelCount {
            guard let data = audioBuffers[channelIndex].mData else { return }
            let sampleOffset = frame * bytesPerChannel
            let value = readSignedIntegerSample(
              rawData: data,
              byteOffset: sampleOffset,
              bytesPerSample: bytesPerChannel,
              bitsPerChannel: bitsPerChannel,
              isBigEndian: isBigEndian,
              isPacked: isPacked,
              isAlignedHigh: isAlignedHigh
            )
            sum += normalizedSignedIntegerSample(value, bitsPerChannel: bitsPerChannel)
          }
          monoSamples.append(sum / Double(channelCount))
        }
        return
      }

      debugPrint(
        "[AppleAudioEngine] waveform decode unsupported noninterleaved PCM " +
        "commonFormat=\(buffer.format.commonFormat.rawValue) " +
        "bitsPerChannel=\(bitsPerChannel) " +
        "flags=\(flags)"
      )
      return
    }

    guard let rawData = buffer.audioBufferList.pointee.mBuffers.mData else {
      debugPrint(
        "[AppleAudioEngine] waveform decode missing interleaved data " +
        "commonFormat=\(buffer.format.commonFormat.rawValue)"
      )
      return
    }

    if isFloat, bitsPerChannel == 32 {
      let samples: UnsafeMutablePointer<Float> = rawData.assumingMemoryBound(to: Float.self)
      for frame in 0..<frameLength {
        var sum = 0.0
        let frameOffset = frame * channelCount
        for channelIndex in 0..<channelCount {
          let sampleIndex = frameOffset + channelIndex
          sum += Double(samples[sampleIndex])
        }
        monoSamples.append(sum / Double(channelCount))
      }
      return
    }

    if isFloat, bitsPerChannel == 64 {
      let samples: UnsafeMutablePointer<Double> = rawData.assumingMemoryBound(to: Double.self)
      for frame in 0..<frameLength {
        var sum = 0.0
        let frameOffset = frame * channelCount
        for channelIndex in 0..<channelCount {
          let sampleIndex = frameOffset + channelIndex
          sum += samples[sampleIndex]
        }
        monoSamples.append(sum / Double(channelCount))
      }
      return
    }

    if isSignedInteger, bitsPerChannel == 16 {
      let samples: UnsafeMutablePointer<Int16> = rawData.assumingMemoryBound(to: Int16.self)
      for frame in 0..<frameLength {
        var sum = 0.0
        let frameOffset = frame * channelCount
        for channelIndex in 0..<channelCount {
          let sampleIndex = frameOffset + channelIndex
          sum += Double(samples[sampleIndex]) / int16Scale
        }
        monoSamples.append(sum / Double(channelCount))
      }
      return
    }

    if isSignedInteger, bitsPerChannel == 32 {
      let samples: UnsafeMutablePointer<Int32> = rawData.assumingMemoryBound(to: Int32.self)
      for frame in 0..<frameLength {
        var sum = 0.0
        let frameOffset = frame * channelCount
        for channelIndex in 0..<channelCount {
          let sampleIndex = frameOffset + channelIndex
          sum += Double(samples[sampleIndex]) / int32Scale
        }
        monoSamples.append(sum / Double(channelCount))
      }
      return
    }

    if isSignedInteger, bitsPerChannel == 24 {
      for frame in 0..<frameLength {
        var sum = 0.0
        let frameOffset = frame * channelCount
        for channelIndex in 0..<channelCount {
          let sampleIndex = frameOffset + channelIndex
          let sampleOffset = sampleIndex * bytesPerChannel
          let value = readSignedIntegerSample(
            rawData: rawData,
            byteOffset: sampleOffset,
            bytesPerSample: bytesPerChannel,
            bitsPerChannel: bitsPerChannel,
            isBigEndian: isBigEndian,
            isPacked: isPacked,
            isAlignedHigh: isAlignedHigh
          )
          sum += normalizedSignedIntegerSample(value, bitsPerChannel: bitsPerChannel)
        }
        monoSamples.append(sum / Double(channelCount))
      }
      return
    }

    debugPrint(
      "[AppleAudioEngine] waveform decode unsupported interleaved PCM " +
      "commonFormat=\(buffer.format.commonFormat.rawValue) " +
      "bitsPerChannel=\(bitsPerChannel) " +
      "flags=\(flags)"
    )
  }

  private static func processWaveform(samples: [Double], expectedChunks: Int) -> [Double] {
    guard expectedChunks > 0 else { return [] }
    guard !samples.isEmpty else {
      return Array(repeating: 0.0, count: expectedChunks)
    }

    let windowCount = max(
      expectedChunks,
      min(samples.count, expectedChunks * waveformRmsWindowsPerChunk)
    )
    var envelope = Array(repeating: 0.0, count: windowCount)

    for window in 0..<windowCount {
      let start = (window * samples.count) / windowCount
      let end = ((window + 1) * samples.count) / windowCount
      guard end > start else { continue }
      envelope[window] = computeRms(samples: samples, start: start, end: end)
    }

    var output = Array(repeating: 0.0, count: expectedChunks)
    for chunk in 0..<expectedChunks {
      let start = (chunk * windowCount) / expectedChunks
      let end = ((chunk + 1) * windowCount) / expectedChunks
      var maxValue = 0.0
      if end > start {
        for index in start..<end {
          if envelope[index] > maxValue {
            maxValue = envelope[index]
          }
        }
      }
      output[chunk] = roundWaveformPrecision(max(0.0, min(maxValue, 1.0)))
    }
    return output
  }

  private static func computeRms(samples: [Double], start: Int, end: Int) -> Double {
    guard end > start else { return 0.0 }
    var sum = 0.0
    for index in start..<end {
      let sample = samples[index]
      sum += sample * sample
    }
    return sqrt(sum / Double(end - start))
  }

  private static func roundWaveformPrecision(_ value: Double) -> Double {
    (value * waveformPrecisionScale).rounded() / waveformPrecisionScale
  }

  private static func signedIntegerScale(bitsPerChannel: Int, fallbackBitsPerChannel: Int) -> Double {
    let resolvedBits = bitsPerChannel > 0 ? bitsPerChannel : fallbackBitsPerChannel
    let clampedBits = max(1, min(resolvedBits, 32))
    if clampedBits >= 32 {
      return Double(Int32.max)
    }
    return Double((Int64(1) << (clampedBits - 1)) - 1)
  }

  private static func normalizedSignedIntegerSample(_ value: Int32, bitsPerChannel: Int) -> Double {
    Double(value) / signedIntegerScale(
      bitsPerChannel: bitsPerChannel,
      fallbackBitsPerChannel: min(max(bitsPerChannel, 1), 32)
    )
  }

  private static func readSignedIntegerSample(
    rawData: UnsafeMutableRawPointer,
    byteOffset: Int,
    bytesPerSample: Int,
    bitsPerChannel: Int,
    isBigEndian: Bool,
    isPacked: Bool,
    isAlignedHigh: Bool
  ) -> Int32 {
    let safeBytesPerSample = max(1, min(bytesPerSample, 4))
    let source = rawData.advanced(by: byteOffset).assumingMemoryBound(to: UInt8.self)
    var assembled: UInt32 = 0

    if isBigEndian {
      for byteIndex in 0..<safeBytesPerSample {
        assembled = (assembled << 8) | UInt32(source[byteIndex])
      }
    } else {
      for byteIndex in 0..<safeBytesPerSample {
        assembled |= UInt32(source[byteIndex]) << (byteIndex * 8)
      }
    }

    let storageBits = safeBytesPerSample * 8
    let effectiveBits: Int
    if isPacked {
      effectiveBits = min(bitsPerChannel, storageBits)
    } else if isAlignedHigh {
      effectiveBits = storageBits
    } else {
      effectiveBits = min(bitsPerChannel, storageBits)
    }

    let signedStorage = Int32(bitPattern: assembled)
    let shifted: Int32
    if !isPacked && isAlignedHigh && storageBits > bitsPerChannel {
      shifted = signedStorage >> (storageBits - bitsPerChannel)
    } else {
      shifted = signedStorage
    }

    if effectiveBits >= 32 {
      return shifted
    }

    let signShift = 32 - effectiveBits
    return (shifted << signShift) >> signShift
  }
}
