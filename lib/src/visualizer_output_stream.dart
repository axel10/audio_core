import 'dart:async';

import 'fft_frame.dart';
import 'fft_processor.dart';
import 'visualizer_output_config.dart';

/// A single visualizer output stream with independent FFT processing configuration.
///
/// Each VisualizerOutputStream maintains its own FftProcessor instance,
/// allowing different smoothing, grouping, and rendering parameters
/// for different visualization styles.
class VisualizerOutputStream {
  VisualizerOutputStream({
    required VisualizerOutputConfig config,
    required List<double> Function() fftSourceProvider,
    required bool sourceAlreadyGrouped,
  }) : _config = config,
       _fftSourceProvider = fftSourceProvider,
       _sourceAlreadyGrouped = sourceAlreadyGrouped {
    _fftProcessor = FftProcessor(fftSize: 1024, options: config.options);
    // Listen to stream subscription to auto-start/stop
    _fftStreamController.onListen = _onListen;
    _fftStreamController.onCancel = _onCancel;
  }

  final VisualizerOutputConfig _config;
  final List<double> Function() _fftSourceProvider;
  final bool _sourceAlreadyGrouped;
  late final FftProcessor _fftProcessor;

  final StreamController<FftFrame> _fftStreamController =
      StreamController<FftFrame>.broadcast();

  Timer? _renderTimer;
  int _lastAnalysisMicros = 0;
  bool _isActive = false;
  bool _isPlaying = true;
  int _listenerCount = 0;

  void _onListen() {
    _listenerCount++;
    if (!_isActive) {
      start();
    }
  }

  void _onCancel() {
    _listenerCount--;
    if (_listenerCount <= 0 && _isActive) {
      _listenerCount = 0;
      stop();
    }
  }

  /// Unique identifier for this output stream.
  String get id => _config.id;

  /// Human-readable label.
  String? get label => _config.label;

  /// Current configuration.
  VisualizerOutputConfig get config => _config;

  /// Current FFT processing options.
  VisualizerOptimizationOptions get options => _fftProcessor.options;

  /// Whether this output stream is currently active (running).
  bool get isActive => _isActive;

  /// Whether this stream has listeners.
  bool get hasListeners => _fftStreamController.hasListener;

  /// Stream of FFT frames for visualization.
  Stream<FftFrame> get fftStream => _fftStreamController.stream;

  /// Current latest FFT values.
  List<double> get latestFft => _fftProcessor.latestOptimizedFft;

  /// Starts the render timer for this output stream.
  void start() {
    _isActive = true;
    _lastAnalysisMicros = 0;
    // 已经在跑就重启一次即可：暂停衰减到底时定时器会自行停表，
    // 但 [_isActive] 仍是 true，这里必须允许补起来，不能提前 return。
    if (_renderTimer == null) {
      _restartRenderTimer();
    }
  }

  /// Stops the render timer.
  void stop() {
    _isActive = false;
    _renderTimer?.cancel();
    _renderTimer = null;
    _fftProcessor.resetState();
  }

  /// 同步播放状态。
  ///
  /// 暂停后不再取真实采样，改为每 tick 让当前频谱按 gravity 自然落下
  /// （[FftProcessor.decayTowardsSilence]），落到静止即停表；恢复播放时
  /// 重新起表。这样暂停不会定格，也不会让 60Hz 定时器空转标脏 UI。
  void setPlaying(bool isPlaying) {
    if (_isPlaying == isPlaying) return;
    _isPlaying = isPlaying;
    if (isPlaying) {
      _lastAnalysisMicros = 0;
      if (_isActive && _renderTimer == null) {
        _restartRenderTimer();
      }
    }
  }

  /// 当前是否处于播放态（供调试/测试读取）。
  bool get isPlaying => _isPlaying;

  /// Restarts the render timer with current frame rate.
  void _restartRenderTimer() {
    _renderTimer?.cancel();
    final frameRate = _config.targetFrameRate;
    if (frameRate <= 0) return;

    final interval = Duration(microseconds: (1000000.0 / frameRate).round());
    _renderTimer = Timer.periodic(interval, (_) => _onRenderTick());
  }

  void _onRenderTick() {
    if (!_isActive || !_fftStreamController.hasListener) {
      return;
    }

    if (!_isPlaying) {
      _tickPausedDecay();
      return;
    }

    // Get latest FFT data from source
    final rawBins = _fftSourceProvider();
    if (rawBins.isEmpty) {
      return;
    }

    // Process analysis (only when we have a significant time gap)
    final analysisNowMicros = DateTime.now().microsecondsSinceEpoch;
    final dtSec = _lastAnalysisMicros == 0
        ? (1000000.0 / 30.0) / 1000000.0
        : (analysisNowMicros - _lastAnalysisMicros) / 1000000.0;
    _lastAnalysisMicros = analysisNowMicros;

    _fftProcessor.processAnalysis(
      rawBins,
      dtSec,
      sourceAlreadyGrouped: _sourceAlreadyGrouped,
    );

    // Process render for interpolation
    _fftProcessor.processRender(_renderIntervalMicros, _analysisIntervalMicros);

    // Emit frame
    _emitFftFrame();
  }

  /// 暂停态：只让频谱落下，不再取真实采样。
  ///
  /// 落到底就停表 —— 订阅方（列表小图标 / 迷你播放器频谱）此时拿到的是
  /// 全零，继续以 60Hz 推送只会让 UI 反复标脏出帧。
  void _tickPausedDecay() {
    final nowMicros = DateTime.now().microsecondsSinceEpoch;
    final dtSec = _lastAnalysisMicros == 0
        ? 1.0 / 60.0
        : (nowMicros - _lastAnalysisMicros) / 1000000.0;
    _lastAnalysisMicros = nowMicros;

    _fftProcessor.decayTowardsSilence(dtSec);
    _fftProcessor.processRender(_renderIntervalMicros, _analysisIntervalMicros);
    _emitFftFrame();

    if (_fftProcessor.isSilent) {
      _renderTimer?.cancel();
      _renderTimer = null;
    }
  }

  int get _renderIntervalMicros {
    final frameRate = _config.targetFrameRate;
    return frameRate > 0 ? (1000000.0 / frameRate).round() : 16667;
  }

  int get _analysisIntervalMicros {
    return 33333; // 30Hz analysis
  }

  void _emitFftFrame() {
    if (_fftStreamController.isClosed) {
      return;
    }
    _fftStreamController.add(
      FftFrame(
        position: Duration.zero, // Position is updated by the manager
        values: _fftProcessor.latestOptimizedFft,
        isPlaying: _isPlaying,
      ),
    );
  }

  /// Updates the FFT processing options.
  void updateOptions(VisualizerOptimizationOptions newOptions) {
    final frameRateChanged =
        (_config.targetFrameRate - newOptions.targetFrameRate).abs() > 1e-9;

    _fftProcessor.updateOptions(newOptions);

    if (frameRateChanged && _isActive) {
      _restartRenderTimer();
    }
  }

  /// Updates the configuration.
  void updateConfig(VisualizerOutputConfig newConfig) {
    // Update options if changed
    if (newConfig.options != options) {
      updateOptions(newConfig.options);
    }

    // Restart timer if frame rate changed
    if ((_config.targetFrameRate - newConfig.targetFrameRate).abs() > 1e-9) {
      if (_isActive) {
        _restartRenderTimer();
      }
    }
  }

  /// Resets the FFT state.
  void resetState() {
    _fftProcessor.resetState();
    _lastAnalysisMicros = 0;
  }

  /// Disposes this output stream.
  void dispose() {
    stop();
    _fftStreamController.close();
  }
}
