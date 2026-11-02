import 'visualizer_output_config.dart';
import 'visualizer_output_stream.dart';

/// Manages multiple visualizer output streams with independent configurations.
///
/// This class allows creating multiple FFT processing pipelines,
/// each with its own configuration, from a single audio source.
class VisualizerOutputManager {
  VisualizerOutputManager({
    required List<double> Function() fftSourceProvider,
    required bool sourceAlreadyGrouped,
  }) : _fftSourceProvider = fftSourceProvider,
       _sourceAlreadyGrouped = sourceAlreadyGrouped {
    _initDefaultOutput();
  }

  final List<double> Function() _fftSourceProvider;
  final bool _sourceAlreadyGrouped;

  final Map<String, VisualizerOutputStream> _outputs = {};
  bool _disposed = false;

  /// 最近一次同步过来的播放态。新建输出流时先对齐它，
  /// 否则暂停期间新挂上的输出流会以「播放中」起表、白转一轮。
  bool _isPlaying = true;

  /// All output stream IDs.
  List<String> get outputIds => List<String>.unmodifiable(_outputs.keys);

  /// Number of output streams.
  int get outputCount => _outputs.length;

  /// Whether this manager has been disposed.
  bool get isDisposed => _disposed;

  /// Creates a new output stream with the given configuration.
  ///
  /// Returns the created VisualizerOutputStream.
  /// Throws [StateError] if an output with the same ID already exists.
  VisualizerOutputStream createOutput(VisualizerOutputConfig config) {
    if (_disposed) {
      throw StateError('VisualizerOutputManager has been disposed');
    }
    if (_outputs.containsKey(config.id)) {
      throw StateError('Output with id "${config.id}" already exists');
    }

    final output = VisualizerOutputStream(
      config: config,
      fftSourceProvider: _fftSourceProvider,
      sourceAlreadyGrouped: _sourceAlreadyGrouped,
    );
    output.setPlaying(_isPlaying);
    _outputs[config.id] = output;

    return output;
  }

  /// Retrieves an output stream by ID, or null if not found.
  VisualizerOutputStream? getOutput(String id) {
    return _outputs[id];
  }

  /// Checks whether an output with the given ID exists.
  bool hasOutput(String id) {
    return _outputs.containsKey(id);
  }

  /// Removes an output stream by ID.
  ///
  /// Returns the removed VisualizerOutputStream, or null if not found.
  VisualizerOutputStream? removeOutput(String id) {
    final output = _outputs.remove(id);
    output?.dispose();
    return output;
  }

  /// Gets the default output stream (created automatically).
  VisualizerOutputStream? get defaultOutput => _outputs['default'];

  /// Creates the default output stream with default configuration.
  void _initDefaultOutput() {
    final config = const VisualizerOutputConfig(
      id: 'default',
      label: 'Default',
      frequencyGroups: 32,
      targetFrameRate: 60.0,
    );
    final output = VisualizerOutputStream(
      config: config,
      fftSourceProvider: _fftSourceProvider,
      sourceAlreadyGrouped: _sourceAlreadyGrouped,
    );
    _outputs[config.id] = output;
  }

  /// Starts all output streams that have listeners.
  void startAll() {
    if (_disposed) return;
    for (final output in _outputs.values) {
      if (output.hasListeners) {
        output.start();
      }
    }
  }

  /// Stops all output streams.
  void stopAll() {
    for (final output in _outputs.values) {
      output.stop();
    }
  }

  /// Resets FFT state for all outputs.
  void resetAll() {
    for (final output in _outputs.values) {
      output.resetState();
    }
  }

  /// Updates the position and playing state for all outputs.
  ///
  /// 暂停态会转发给每个输出流：它们不再取真实采样，而是让当前频谱按
  /// gravity 自然落下，落到底自行停表；恢复播放时重新起表。
  void updatePlaybackState(Duration position, bool isPlaying) {
    _isPlaying = isPlaying;
    for (final output in _outputs.values) {
      output.setPlaying(isPlaying);
    }
  }

  /// Disposes all output streams and clears the manager.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final output in _outputs.values) {
      output.dispose();
    }
    _outputs.clear();
  }
}
