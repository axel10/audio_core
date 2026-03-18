import 'fft_processor.dart';

/// Configuration for a single visualizer output stream.
///
/// Each output stream can have its own FFT processing options,
/// allowing multiple visualizations with different characteristics
/// from a single audio source.
class VisualizerOutputConfig {
  const VisualizerOutputConfig({
    required this.id,
    this.label,
    VisualizerOptimizationOptions? options,
    this.frequencyGroups = 32,
    this.targetFrameRate = 60.0,
    this.enabled = true,
  }) : _options = options;

  /// Unique identifier for this output stream.
  final String id;

  /// Human-readable label for this output (e.g., "Bar Style", "Circle Style").
  final String? label;

  final VisualizerOptimizationOptions? _options;

  /// FFT processing options for this output stream.
  /// If null, uses default options.
  VisualizerOptimizationOptions get options =>
      _options ??
      VisualizerOptimizationOptions(
        frequencyGroups: frequencyGroups,
        targetFrameRate: targetFrameRate,
      );

  /// Number of output frequency groups.
  final int frequencyGroups;

  /// Target frame rate for this output stream.
  final double targetFrameRate;

  /// Whether this output stream is enabled.
  /// When disabled, the stream will not emit FFT frames.
  final bool enabled;

  /// Creates a copy of this config with the given fields replaced.
  VisualizerOutputConfig copyWith({
    String? id,
    String? label,
    VisualizerOptimizationOptions? options,
    int? frequencyGroups,
    double? targetFrameRate,
    bool? enabled,
  }) {
    return VisualizerOutputConfig(
      id: id ?? this.id,
      label: label ?? this.label,
      options: options ?? _options,
      frequencyGroups: frequencyGroups ?? this.frequencyGroups,
      targetFrameRate: targetFrameRate ?? this.targetFrameRate,
      enabled: enabled ?? this.enabled,
    );
  }
}
