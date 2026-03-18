/// A single FFT frame emitted by the player.
///
/// Contains the playback [position], FFT [values], and whether the player
/// was [isPlaying] when this frame was produced.
class FftFrame {
  const FftFrame({
    required this.position,
    required this.values,
    required this.isPlaying,
  });

  /// Playback position associated with this frame.
  final Duration position;

  /// FFT magnitudes for this frame.
  final List<double> values;

  /// Whether playback was active when this frame was sampled.
  final bool isPlaying;
}
