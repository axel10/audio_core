import 'dart:io';

import 'android_audio_file_access.dart';
import 'android_audio_engine.dart';
import 'apple_audio_file_access.dart';
import 'apple_audio_engine.dart';
import 'audio_analysis_service.dart';
import 'audio_file_access.dart';
import 'audio_engine_interface.dart';
import 'noop_audio_file_access.dart';
import 'rust_audio_analysis_service.dart';
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

AudioAnalysisService createDefaultAudioAnalysisService() {
  return const RustAudioAnalysisService();
}

AudioFileAccess createDefaultAudioFileAccess() {
  if (Platform.isAndroid) {
    return AndroidAudioFileAccess();
  }
  if (Platform.isIOS || Platform.isMacOS) {
    return AppleAudioFileAccess();
  }
  return const NoopAudioFileAccess();
}
