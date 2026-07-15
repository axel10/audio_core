#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint audio_core.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
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
  s.source_files     = 'audio_core/Sources/audio_core/**/*'
  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'

  s.ios.deployment_target = '15.0'
  s.osx.deployment_target = '13.0'
  s.swift_version = '5.0'

  ffmpeg_root = '$(PODS_TARGET_SRCROOT)/FFmpeg.xcframework'

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

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'SWIFT_INCLUDE_PATHS' => '$(PODS_CONFIGURATION_BUILD_DIR)',
    'FRAMEWORK_SEARCH_PATHS' => '$(PODS_CONFIGURATION_BUILD_DIR)',
    'OTHER_LDFLAGS' => [
      '$(inherited)',
      '-lm',
      '-lz',
      '-lbz2',
      '-liconv',
      '-framework', 'AudioToolbox',
      '-framework', 'AVFoundation',
      '-framework', 'CoreMedia',
      '-framework', 'VideoToolbox',
      '-force_load ${BUILT_PRODUCTS_DIR}/libaudio_core.a',
    ].join(' '),
  }

  s.ios.pod_target_xcconfig = {
    'HEADER_SEARCH_PATHS' => '$(inherited)',
    'LIBRARY_SEARCH_PATHS[sdk=iphoneos*]' => "$(inherited) #{ffmpeg_root}/ios-arm64",
    'LIBRARY_SEARCH_PATHS[sdk=iphonesimulator*]' => "$(inherited) #{ffmpeg_root}/ios-arm64_x86_64-simulator",
    'OTHER_LDFLAGS' => '$(inherited) -lffmpeg',
  }

  s.osx.pod_target_xcconfig = {
    'HEADER_SEARCH_PATHS' => '$(inherited)',
    'LIBRARY_SEARCH_PATHS' => "$(inherited) #{ffmpeg_root}/macos-arm64_x86_64",
    'OTHER_LDFLAGS' => '$(inherited) -lffmpeg',
  }
end
