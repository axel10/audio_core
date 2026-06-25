import 'dart:io';

import 'android_audio_engine.dart';
import 'apple_audio_engine.dart';
import 'audio_engine_interface.dart';
import 'rust_audio_engine.dart';

/// Creates the default engine implementation for the current platform.
AudioEngine createDefaultAudioEngine() {
  if (Platform.isAndroid) {
    return AndroidAudioEngine();
  }
  if (Platform.isIOS || Platform.isMacOS) {
    return AppleAudioEngine();
  }
  return RustAudioEngine();
}
