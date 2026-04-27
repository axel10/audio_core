import 'package:audio_core/src/audio_engine/audio_engine_interface.dart';
import 'package:audio_core/src/visualizer_player_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('auto-advances when native backend reports ENDED', () {
    expect(
      shouldAutoAdvanceFromStatus(
        AudioStatus(
          playbackState: 'ENDED',
          position: const Duration(minutes: 3),
          duration: const Duration(minutes: 3),
          isPlaying: false,
          volume: 1.0,
        ),
      ),
      isTrue,
    );
  });

  test('does not auto-advance for a mid-track pause', () {
    expect(
      shouldAutoAdvanceFromStatus(
        AudioStatus(
          playbackState: null,
          position: const Duration(minutes: 1, seconds: 15),
          duration: const Duration(minutes: 3),
          isPlaying: false,
          volume: 1.0,
        ),
      ),
      isFalse,
    );
  });

  test('does not auto-advance without an explicit ENDED state', () {
    expect(
      shouldAutoAdvanceFromStatus(
        AudioStatus(
          playbackState: null,
          position: const Duration(minutes: 3),
          duration: const Duration(minutes: 3),
          isPlaying: false,
          volume: 1.0,
        ),
      ),
      isFalse,
    );
  });
}
