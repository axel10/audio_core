import AVFoundation
import Foundation

extension AppleAudioEngine {
  func setEqualizerConfig(_ config: AppleEqualizerConfig) {
    let sanitizedConfig = AppleEqualizerCodec.sanitized(config)
    latestEqualizerConfig = sanitizedConfig
    applyEqualizerConfig(sanitizedConfig)
  }

  func getEqualizerConfig() -> AppleEqualizerConfig {
    latestEqualizerConfig
  }

  func applyEqualizerConfig(_ config: AppleEqualizerConfig) {
    let availableBandCount = equalizerNode.bands.count
    let userBandCount = min(AppleEqualizerDefaults.maxBands, max(0, availableBandCount - 1))
    let clampedBandCount = max(0, min(config.bandCount, userBandCount))
    let bandFrequencies = Self.bandCenterFrequencies(count: AppleEqualizerDefaults.maxBands)
    let maxBoostDb = Self.maxBoostDb(for: config, userBandCount: clampedBandCount)
    let compensatedPreampDb = config.preampDb - maxBoostDb

    equalizerNode.globalGain = Float(config.enabled ? compensatedPreampDb : 0.0)
    let eqBandwidth = Self.bandwidthInOctaves(forQ: AppleEqualizerDefaults.eqBandQ)
    let bassBandwidth = Self.bandwidthInOctaves(forQ: config.bassBoostQ)

    for index in 0..<userBandCount {
      let band = equalizerNode.bands[index]
      band.bypass = !config.enabled || index >= clampedBandCount
      band.filterType = .parametric
      band.frequency = Float(bandFrequencies[index])
      band.gain = index < config.bandGainsDb.count ? Float(config.bandGainsDb[index]) : 0.0
      band.bandwidth = eqBandwidth
    }

    if availableBandCount > userBandCount {
      let bassBand = equalizerNode.bands[userBandCount]
      bassBand.bypass = !config.enabled || abs(config.bassBoostDb) <= AppleEqualizerDefaults.epsilonGainDb
      bassBand.filterType = .resonantLowShelf
      bassBand.frequency = Float(config.bassBoostFrequencyHz)
      bassBand.gain = Float(config.bassBoostDb)
      bassBand.bandwidth = bassBandwidth
    }
  }

  static func bandwidthInOctaves(forQ q: Double) -> Float {
    let safeQ = max(q, 0.0001)
    let root = (1.0 + sqrt(1.0 + 4.0 * safeQ * safeQ)) / (2.0 * safeQ)
    let bandwidth = 2.0 * log2(root)
    return Float(max(0.05, min(bandwidth, 6.0)))
  }

  static func maxBoostDb(for config: AppleEqualizerConfig, userBandCount: Int) -> Double {
    var maxBoostDb = max(0.0, config.bassBoostDb)
    for index in 0..<min(userBandCount, config.bandGainsDb.count) {
      maxBoostDb = max(maxBoostDb, config.bandGainsDb[index])
    }
    return maxBoostDb
  }

  static func bandCenterFrequencies(count: Int) -> [Double] {
    let safeCount = max(count, 1)
    if safeCount == 1 {
      return [1000.0]
    }

    let minFrequency = AppleEqualizerDefaults.minCenterFrequencyHz
    let maxFrequency = AppleEqualizerDefaults.maxCenterFrequencyHz
    let ratio = maxFrequency / minFrequency
    return (0..<safeCount).map { index in
      let exponent = Double(index) / Double(safeCount - 1)
      return minFrequency * pow(ratio, exponent)
    }
  }
}
