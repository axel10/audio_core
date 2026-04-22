import Foundation

struct AppleEqualizerConfig {
  let enabled: Bool
  let bandCount: Int
  let preampDb: Double
  let bassBoostDb: Double
  let bassBoostFrequencyHz: Double
  let bassBoostQ: Double
  let bandGainsDb: [Double]
}

enum AppleEqualizerDefaults {
  static let maxBands = 20
  static let minCenterFrequencyHz = 32.0
  static let maxCenterFrequencyHz = 16_000.0
  static let defaultBassBoostFrequencyHz = 80.0
  static let defaultBassBoostQ = 0.75
  static let eqBandQ = 1.0
  static let epsilonGainDb = 0.001
}

enum AppleEqualizerCodec {
  static func readConfig(_ arguments: Any?) -> AppleEqualizerConfig? {
    guard let map = arguments as? [String: Any] else { return nil }

    let enabled = (map["enabled"] as? Bool) ?? false
    let bandCount = readInt(map, key: "bandCount") ?? 0
    let preampDb = readDouble(map, key: "preampDb") ?? 0.0
    let bassBoostDb = readDouble(map, key: "bassBoostDb") ?? 0.0
    let bassBoostFrequencyHz =
      readDouble(map, key: "bassBoostFrequencyHz")
      ?? AppleEqualizerDefaults.defaultBassBoostFrequencyHz
    let bassBoostQ = readDouble(map, key: "bassBoostQ") ?? AppleEqualizerDefaults.defaultBassBoostQ

    let rawBands = map["bandGainsDb"] as? [Any] ?? []
    var bandGainsDb = Array(repeating: 0.0, count: AppleEqualizerDefaults.maxBands)
    for index in 0..<min(rawBands.count, bandGainsDb.count) {
      if let value = rawBands[index] as? Double {
        bandGainsDb[index] = value
      } else if let value = rawBands[index] as? Int {
        bandGainsDb[index] = Double(value)
      } else if let value = rawBands[index] as? Int64 {
        bandGainsDb[index] = Double(value)
      } else if let value = rawBands[index] as? NSNumber {
        bandGainsDb[index] = value.doubleValue
      }
    }

    return sanitized(
      AppleEqualizerConfig(
        enabled: enabled,
        bandCount: bandCount,
        preampDb: preampDb,
        bassBoostDb: bassBoostDb,
        bassBoostFrequencyHz: bassBoostFrequencyHz,
        bassBoostQ: bassBoostQ,
        bandGainsDb: bandGainsDb
      )
    )
  }

  static func sanitized(_ config: AppleEqualizerConfig) -> AppleEqualizerConfig {
    var gains = Array(repeating: 0.0, count: AppleEqualizerDefaults.maxBands)
    for index in 0..<min(config.bandGainsDb.count, gains.count) {
      gains[index] = config.bandGainsDb[index]
    }

    return AppleEqualizerConfig(
      enabled: config.enabled,
      bandCount: max(0, min(config.bandCount, AppleEqualizerDefaults.maxBands)),
      preampDb: config.preampDb,
      bassBoostDb: config.bassBoostDb,
      bassBoostFrequencyHz: config.bassBoostFrequencyHz.clamped(to: 20.0...240.0),
      bassBoostQ: config.bassBoostQ.clamped(to: 0.1...2.0),
      bandGainsDb: gains
    )
  }

  static func payload(_ config: AppleEqualizerConfig) -> [String: Any] {
    [
      "enabled": config.enabled,
      "bandCount": config.bandCount,
      "preampDb": config.preampDb,
      "bassBoostDb": config.bassBoostDb,
      "bassBoostFrequencyHz": config.bassBoostFrequencyHz,
      "bassBoostQ": config.bassBoostQ,
      "bandGainsDb": config.bandGainsDb,
    ]
  }

  static func defaultConfig() -> AppleEqualizerConfig {
    AppleEqualizerConfig(
      enabled: false,
      bandCount: AppleEqualizerDefaults.maxBands,
      preampDb: 0.0,
      bassBoostDb: 0.0,
      bassBoostFrequencyHz: AppleEqualizerDefaults.defaultBassBoostFrequencyHz,
      bassBoostQ: AppleEqualizerDefaults.defaultBassBoostQ,
      bandGainsDb: Array(repeating: 0.0, count: AppleEqualizerDefaults.maxBands)
    )
  }

  private static func readInt(_ map: [String: Any], key: String) -> Int? {
    if let value = map[key] as? Int { return value }
    if let value = map[key] as? Int64 { return Int(value) }
    if let value = map[key] as? Double { return Int(value) }
    if let value = map[key] as? NSNumber { return value.intValue }
    return nil
  }

  private static func readDouble(_ map: [String: Any], key: String) -> Double? {
    if let value = map[key] as? Double { return value }
    if let value = map[key] as? Int { return Double(value) }
    if let value = map[key] as? Int64 { return Double(value) }
    if let value = map[key] as? NSNumber { return value.doubleValue }
    return nil
  }
}

private extension Comparable {
  func clamped(to limits: ClosedRange<Self>) -> Self {
    min(max(self, limits.lowerBound), limits.upperBound)
  }
}
