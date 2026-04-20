import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'player_models.dart';
import 'rust/api/simple/equalizer.dart';

/// Manages equalizer and bass boost configuration.
class EqualizerController extends ChangeNotifier {
  EqualizerController({required AudioVisualizerParent parent})
    : _parent = parent;

  final AudioVisualizerParent _parent;

  static const int maxEqualizerBands = 20;
  static const double minFrequencyHz = 32.0;
  static const double maxFrequencyHz = 16000.0;
  static const double bassBoostFrequencyHz = 80.0;
  static const double bassBoostQ = 0.75;

  EqualizerConfig _config = _makeDefaultConfig();
  EqualizerConfig get config => _config;

  bool _isAdvanced = true;
  bool get isAdvanced => _isAdvanced;

  // System EQ states (Android only)
  Map<String, dynamic>? _systemParams;
  Map<String, dynamic>? get systemParams => _systemParams;
  List<double> _systemBandGains = [];
  double _systemBassBoostDb = 0.0;

  @internal
  Future<void> initialize() async {
    try {
      _config = await _parent.engine.getEqualizerConfig();
      notifyListeners();
    } catch (e) {
      debugPrint('[EqualizerController] initialization error: $e');
    }
  }

  Future<void> setAdvanced(bool advanced) async {
    _isAdvanced = advanced;
    await setConfig(_config);
    notifyListeners();
  }

  Future<void> reapply() async {
    if (Platform.isAndroid) {
      await setAdvanced(_isAdvanced);
    } else {
      await setConfig(_config);
    }
  }

  Future<void> _updateSystemEq() async {
    // Legacy support for system EQ removed to streamline integration
  }

  Future<void> setConfig(EqualizerConfig config) async {
    final normalized = _normalizeConfig(config);
    try {
      await _parent.engine.setEqualizerConfig(normalized);
      _config = normalized;
      notifyListeners();
    } catch (e) {
      debugPrint('[EqualizerController] update failed: $e');
      rethrow;
    }
  }

  // System EQ specific setters
  Future<void> setSystemBandGain(int index, double gain) async {
    if (index < 0 || index >= _systemBandGains.length) return;
    _systemBandGains[index] = gain;
    await _updateSystemEq();
    notifyListeners();
  }

  Future<void> setSystemBassBoost(double gainDb) async {
    _systemBassBoostDb = gainDb;
    await _updateSystemEq();
    notifyListeners();
  }

  double getSystemBandGain(int index) {
    if (index < 0 || index >= _systemBandGains.length) return 0.0;
    return _systemBandGains[index];
  }

  double get systemBassBoostDb => _systemBassBoostDb;

  Future<void> setEnabled(bool enabled) async =>
      setConfig(_copyConfig(enabled: enabled));

  Future<void> setBandCount(int bandCount) async =>
      setConfig(_copyConfig(bandCount: bandCount));

  Future<void> setBandGain(int bandIndex, double gainDb) async {
    if (bandIndex < 0 || bandIndex >= maxEqualizerBands) return;
    final gains = Float32List.fromList(_config.bandGainsDb.toList());
    gains[bandIndex] = gainDb;
    await setConfig(_copyConfig(bandGainsDb: gains));
  }

  Future<void> setPreamp(double preampDb) async =>
      setConfig(_copyConfig(preampDb: preampDb));

  Future<void> setBassBoost(double gainDb) async =>
      setConfig(_copyConfig(bassBoostDb: gainDb));

  void resetDefaults() {
    if (_isAdvanced || !Platform.isAndroid) {
      setConfig(_makeDefaultConfig());
    } else {
      _systemBandGains = List.filled(_systemBandGains.length, 0.0);
      _systemBassBoostDb = 0.0;
      unawaited(_updateSystemEq());
      notifyListeners();
    }
  }

  List<double> getBandCenters({int? bandCount}) {
    final count = (bandCount ?? _config.bandCount).clamp(0, maxEqualizerBands);
    if (count <= 0) return const [];
    if (count == 1) return const [1000.0];
    final ratio = maxFrequencyHz / minFrequencyHz;
    return List.generate(
      count,
      (i) => minFrequencyHz * math.pow(ratio, i / (count - 1)).toDouble(),
      growable: false,
    );
  }

  static EqualizerConfig _makeDefaultConfig() => EqualizerConfig(
    enabled: false,
    bandCount: maxEqualizerBands,
    preampDb: 0.0,
    bassBoostDb: 0.0,
    bassBoostFrequencyHz: bassBoostFrequencyHz,
    bassBoostQ: bassBoostQ,
    bandGainsDb: Float32List(maxEqualizerBands),
  );

  EqualizerConfig _normalizeConfig(EqualizerConfig config) {
    final gains = Float32List(maxEqualizerBands);
    for (var i = 0; i < maxEqualizerBands; i++) {
      gains[i] = i < config.bandGainsDb.length ? config.bandGainsDb[i] : 0.0;
    }
    return EqualizerConfig(
      enabled: config.enabled,
      bandCount: config.bandCount.clamp(0, maxEqualizerBands),
      preampDb: config.preampDb,
      bassBoostDb: config.bassBoostDb,
      bassBoostFrequencyHz: config.bassBoostFrequencyHz,
      bassBoostQ: config.bassBoostQ,
      bandGainsDb: gains,
    );
  }

  EqualizerConfig _copyConfig({
    bool? enabled,
    int? bandCount,
    double? preampDb,
    double? bassBoostDb,
    Float32List? bandGainsDb,
  }) {
    return EqualizerConfig(
      enabled: enabled ?? _config.enabled,
      bandCount: bandCount ?? _config.bandCount,
      preampDb: preampDb ?? _config.preampDb,
      bassBoostDb: bassBoostDb ?? _config.bassBoostDb,
      bassBoostFrequencyHz: _config.bassBoostFrequencyHz,
      bassBoostQ: _config.bassBoostQ,
      bandGainsDb: bandGainsDb ?? _config.bandGainsDb,
    );
  }

  @override
  void notifyListeners() {
    super.notifyListeners();
    _parent.notifyListeners();
  }
}
