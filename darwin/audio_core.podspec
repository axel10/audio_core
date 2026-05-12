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
  s.source_files     = ['Classes/**/*']
  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'

  s.ios.deployment_target = '15.0'
  s.osx.deployment_target = '11.0'
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

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'OTHER_LDFLAGS' => [
      '$(inherited)',
      '-lavformat',
      '-lavcodec',
      '-lavfilter',
      '-lavutil',
      '-lswresample',
      '-lswscale',
      '-lmp3lame',
      '-lopus',
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
    'HEADER_SEARCH_PATHS' => [
      '$(inherited)',
      '$(PODS_TARGET_SRCROOT)/../ios/ffmpeg_lib/arm64/include',
      '$(PODS_TARGET_SRCROOT)/../ios/ffmpeg_lib/arm64-sim/include',
    ].join(' '),
    'LIBRARY_SEARCH_PATHS' => [
      '$(inherited)',
      '$(PODS_TARGET_SRCROOT)/../ios/ffmpeg_lib/arm64/lib',
      '$(PODS_TARGET_SRCROOT)/../ios/ffmpeg_lib/arm64-sim/lib',
    ].join(' '),
  }

  s.osx.pod_target_xcconfig = {
    'HEADER_SEARCH_PATHS' => [
      '$(inherited)',
      '$(PODS_TARGET_SRCROOT)/../macos/ffmpeg_lib/arm64/include',
      '$(PODS_TARGET_SRCROOT)/../macos/ffmpeg_lib/x86_64/include',
    ].join(' '),
    'LIBRARY_SEARCH_PATHS' => [
      '$(inherited)',
      '$(PODS_TARGET_SRCROOT)/../macos/ffmpeg_lib/arm64/lib',
      '$(PODS_TARGET_SRCROOT)/../macos/ffmpeg_lib/x86_64/lib',
    ].join(' '),
  }

  s.osx.script_phase = {
    :name => 'Embed FFmpeg Frameworks',
    :script => '
      # 获取当前正在编译的架构 (如果是多个，取第一个)
      ARCH=$(echo $ARCHS | cut -d" " -f1)
      DEST="${BUILT_PRODUCTS_DIR}/${FRAMEWORKS_FOLDER_PATH}"
      SRC="${PODS_TARGET_SRCROOT}/../macos/ffmpeg_lib/${ARCH}/lib"

      echo "Embedding FFmpeg libraries for architecture: ${ARCH}"
      echo "Source: ${SRC}"
      echo "Destination: ${DEST}"

      mkdir -p "${DEST}"
      if [ -d "${SRC}" ]; then
        cp -af "${SRC}/"*.dylib "${DEST}/"
      else
        echo "Error: FFmpeg libraries not found at ${SRC}"
        exit 1
      fi
    ',
    :execution_position => :after_compile,
  }
end
