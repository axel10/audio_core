#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint audio_core.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  ffmpeg_lib_root = '$(PODS_ROOT)/../Flutter/ephemeral/.symlinks/plugins/audio_ffmpeg_lib/ios/ffmpeg_lib'
  s.name             = 'audio_core'
  s.version          = '0.0.1'
  s.summary          = 'A new Flutter FFI plugin project.'
  s.description      = <<-DESC
A new Flutter FFI plugin project.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }

  s.source           = { :path => '.' }
  s.source_files = ['../darwin/Classes/**/*']
  s.dependency 'Flutter'
  s.dependency 'audio_ffmpeg_lib'
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'HEADER_SEARCH_PATHS' => [
      '$(inherited)',
      "#{ffmpeg_lib_root}/arm64/include",
      "#{ffmpeg_lib_root}/arm64-sim/include",
    ].join(' '),
    'LIBRARY_SEARCH_PATHS' => [
      '$(inherited)',
      "#{ffmpeg_lib_root}/arm64/lib",
      "#{ffmpeg_lib_root}/arm64-sim/lib",
    ].join(' '),
    'OTHER_LDFLAGS' => [
      '-force_load ${BUILT_PRODUCTS_DIR}/libaudio_core.a',
      '-L$(PODS_ROOT)/../Flutter/ephemeral/.symlinks/plugins/audio_ffmpeg_lib/ios/ffmpeg_lib/arm64/lib',
      '-L$(PODS_ROOT)/../Flutter/ephemeral/.symlinks/plugins/audio_ffmpeg_lib/ios/ffmpeg_lib/arm64-sim/lib',
      '-lavformat',
      '-lavcodec',
      '-lavutil',
      '-lswresample',
      '-lswscale',
      '-lmp3lame',
      '-lopus',
      '-lm',
      '-lz',
      '-lbz2',
      '-liconv',
      '-framework',
      'AudioToolbox',
      '-framework',
      'AVFoundation',
      '-framework',
      'CoreMedia',
      '-framework',
      'VideoToolbox',
    ].join(' '),
  }
  s.swift_version = '5.0'

  s.script_phase = {
    :name => 'Build Rust library',
    # First argument is relative path to the `rust` folder, second is name of rust library
    :script => 'sh "$PODS_TARGET_SRCROOT/../cargokit/build_pod.sh" ../rust audio_core',
    :execution_position => :before_compile,
    :input_files => ['${BUILT_PRODUCTS_DIR}/cargokit_phony'],
    # Let XCode know that the static library referenced in -force_load below is
    # created by this build step.
    :output_files => ["${BUILT_PRODUCTS_DIR}/libaudio_core.a"],
  }
end
