import 'visualizer_output_config.dart';
import 'visualizer_output_stream.dart';

/// Manages multiple visualizer output streams with independent configurations.
///
/// This class allows creating multiple FFT processing pipelines,
/// each with its own configuration, from a single audio source.
class VisualizerOutputManager {
  VisualizerOutputManager({required List<double> Function() fftSourceProvider})
    : _fftSourceProvider = fftSourceProvider {
    _initDefaultOutput();
  }

  final List<double> Function() _fftSourceProvider;

  final Map<String, VisualizerOutputStream> _outputs = {};
  bool _disposed = false;

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
    );
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
  void updatePlaybackState(Duration position, bool isPlaying) {
    // This could be used to update the FftFrame with correct position
    // For now, outputs fetch position from provider
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
