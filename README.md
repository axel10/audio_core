# audio_core

vibe_flow播放核心

## Android FFmpeg fallback

`audio_core` can use Media3's FFmpeg extension as a fallback decoder on Android,
but the extension only becomes available when FFmpeg shared libraries are
present.

Build flow:

1. `audio_converter` is responsible for producing the Android FFmpeg shared
   libraries.
2. Its Android build copies the FFmpeg `.so` files into
   `audio_converter/android/src/main/jniLibs/<abi>`.
3. `audio_core` then consumes those shared libraries when building the Android
   plugin and enables the vendored Media3 FFmpeg renderer.

Practical requirement:

* If you want FFmpeg fallback in `audio_core`, make sure the project also depends
  on `audio_converter`, and that `audio_converter` has already populated its
  Android FFmpeg assets.
* If the FFmpeg libraries are missing, `audio_core` will still build and run,
  but the FFmpeg extension will stay disabled and ExoPlayer will fall back to
  the normal MediaCodec path.

Implementation notes:

* `audio_core` vendors the Media3 FFmpeg extension source under
  `android/media3-src/decoder_ffmpeg`.
* The Android build no longer depends on the third-party `nextlib-media3ext`
  wrapper.
* The FFmpeg shared objects are not built by `audio_core` itself; they are
  expected to come from `audio_converter`.

## Binding to native code

To use the native code, bindings in Dart are needed.
To avoid writing these by hand, they are generated from the header file
(`src/audio_core.h`) by `package:ffigen`.
Regenerate the bindings by running `dart run ffigen --config ffigen.yaml`.

## Invoking native code

Very short-running native functions can be directly invoked from any isolate.
For example, see `sum` in `lib/audio_core.dart`.

Longer-running functions should be invoked on a helper isolate to avoid
dropping frames in Flutter applications.
For example, see `sumAsync` in `lib/audio_core.dart`.
