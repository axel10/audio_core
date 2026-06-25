import 'package:meta/meta.dart';

import 'audio_engine/audio_engine_interface.dart';
import 'playlist_models.dart';
import 'random_playback_models.dart';

/// Internal delegate shared by sub-controllers owned by [AudioCoreController].
@internal
abstract interface class AudioCoreControllerDelegate {
  void notifyListeners();

  AudioEngine get engine;

  Future<bool> canPlayTrack(AudioTrack track);

  Future<void> loadTrack({
    required bool autoPlay,
    Duration? position,
    PlaybackReason reason,
    FadeSettings? fadeSetting,
  });

  Future<void> clearPlayback();

  Future<bool> handlePlayRequested();
}
