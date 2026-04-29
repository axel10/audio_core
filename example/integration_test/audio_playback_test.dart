import 'dart:async';
import 'dart:io';

import 'package:audio_core/audio_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter/services.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('AudioCoreController playback integration', () {
    late AudioCoreController controller;
    late List<File> audioFiles;
    Directory? extractedMusicDirectory;

    setUpAll(() async {
      controller = AudioCoreController();
      await controller.initialize();
      final extractedTracks = await _discoverLocalTracks();
      extractedMusicDirectory = extractedTracks.$1;
      audioFiles = extractedTracks.$2;
    });

    tearDownAll(() async {
      final directory = extractedMusicDirectory;
      if (directory != null && directory.existsSync()) {
        await directory.delete(recursive: true);
      }
    });

    setUp(() async {
      await controller.resetPlaybackState();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });

    tearDown(() async {
      await controller.clearPlayback();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });

    test('should load a local track and start playback', () async {
      final firstTrack = audioFiles.first;

      await controller.playPaths(<String>[
        firstTrack.path,
      ], autoPlayFirst: false);

      await _waitFor(
        description: 'track to load',
        condition: () {
          return controller.player.currentPath == firstTrack.path &&
              controller.playlist.currentTrack?.uri == firstTrack.path &&
              controller.player.duration > Duration.zero &&
              !controller.player.isPlaying &&
              controller.player.error == null;
        },
      );

      await controller.player.play(withFade: false);

      await _waitFor(
        description: 'track to start playing',
        condition: () {
          return controller.player.currentPath == firstTrack.path &&
              controller.player.isPlaying &&
              controller.player.currentState == PlayerState.playing;
        },
      );

      await _waitFor(
        description: 'playback position to advance',
        timeout: const Duration(seconds: 8),
        condition: () =>
            controller.player.position > const Duration(milliseconds: 800),
      );
    }, skip: !Platform.isMacOS);

    test(
      'should jump to next and previous tracks in queue order',
      () async {
        final queueFiles = _pickQueueFiles(audioFiles, count: 3);
        await controller.playPaths(
          queueFiles.map((file) => file.path).toList(growable: false),
          autoPlayFirst: false,
        );

        final queueTracks = _buildQueueTracks(queueFiles);
        await controller.playlist.updatePlaylistTracks(
          controller.playlist.queuePlaylistId,
          queueTracks,
        );
        await controller.playlist.setActivePlaylist(
          controller.playlist.queuePlaylistId,
          startIndex: 0,
          autoPlay: false,
        );

        await _waitFor(
          description: 'queue to load first track',
          condition: () {
            return controller.playlist.currentTrack?.id == queueTracks[0].id &&
                controller.player.currentPath == queueTracks[0].uri &&
                controller.nextTrack?.id == queueTracks[1].id;
          },
        );

        expect(controller.playlist.currentTrack?.id, queueTracks[0].id);
        expect(controller.nextTrack?.id, queueTracks[1].id);
        expect(controller.previousTrack, isNull);

        final movedNext = await controller.playlist.playNext();
        expect(movedNext, isTrue);

        await _waitFor(
          description: 'next track to become active',
          condition: () {
            return controller.playlist.currentTrack?.id == queueTracks[1].id &&
                controller.player.currentPath == queueTracks[1].uri &&
                controller.player.isPlaying &&
                controller.previousTrack?.id == queueTracks[0].id &&
                controller.nextTrack?.id == queueTracks[2].id;
          },
        );

        final movedPrevious = await controller.playlist.playPrevious();
        expect(movedPrevious, isTrue);

        await _waitFor(
          description: 'previous track to become active again',
          condition: () {
            return controller.playlist.currentTrack?.id == queueTracks[0].id &&
                controller.player.currentPath == queueTracks[0].uri &&
                controller.player.isPlaying &&
                controller.previousTrack == null &&
                controller.nextTrack?.id == queueTracks[1].id;
          },
        );
      },
      skip: !Platform.isMacOS,
    );

    test('should update playback position after seek', () async {
      final firstTrack = audioFiles.first;

      await controller.playPaths(<String>[
        firstTrack.path,
      ], autoPlayFirst: true);

      await _waitFor(
        description: 'track to start playing before seek',
        condition: () {
          return controller.player.currentPath == firstTrack.path &&
              controller.player.duration > const Duration(seconds: 10) &&
              controller.player.isPlaying;
        },
      );

      final target = _seekTargetFor(controller.player.duration);
      await controller.player.seek(target);

      await _waitFor(
        description: 'player position to reach seek target',
        condition: () => _closeTo(controller.player.position, target),
      );

      await Future<void>.delayed(const Duration(milliseconds: 400));
      final nativePosition = await controller.engine.getCurrentPosition();
      expect(
        _closeTo(
          nativePosition.position,
          target,
          tolerance: const Duration(seconds: 2),
        ),
        isTrue,
        reason:
            'native position ${nativePosition.position} should be near target $target',
      );
    }, skip: !Platform.isMacOS);
  });
}

Future<(Directory, List<File>)> _discoverLocalTracks() async {
  if (!Platform.isMacOS) {
    throw TestFailure(
      'These playback integration tests currently target macOS.',
    );
  }

  final supportedExtensions = <String>{'.m4a', '.mp3', '.flac', '.wav', '.aac'};
  const assetPrefix = 'assets/test_music/';
  final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
  final assetPaths = manifest.listAssets().where((path) {
    final normalized = path.toLowerCase();
    return path.startsWith(assetPrefix) &&
        supportedExtensions.any(normalized.endsWith);
  }).toList()..sort();

  if (assetPaths.isEmpty) {
    throw TestFailure(
      'No bundled audio assets found under $assetPrefix. Check example/pubspec.yaml assets.',
    );
  }

  final targetDirectory = await Directory.systemTemp.createTemp(
    'audio_core_test_music_',
  );
  final files = <File>[];

  for (final assetPath in assetPaths) {
    final bytes = await rootBundle.load(assetPath);
    final fileName = assetPath.substring(assetPrefix.length);
    final file = File('${targetDirectory.path}/$fileName');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
    files.add(file);
  }

  if (files.isEmpty) {
    throw TestFailure('No audio files extracted from bundled test assets.');
  }

  return (targetDirectory, files);
}

List<File> _pickQueueFiles(List<File> files, {required int count}) {
  if (files.length < count) {
    throw TestFailure(
      'Expected at least $count audio files for queue navigation test, found ${files.length}.',
    );
  }

  return files.take(count).toList(growable: false);
}

List<AudioTrack> _buildQueueTracks(List<File> files) {
  return List<AudioTrack>.generate(files.length, (index) {
    final file = files[index];
    final absolutePath = file.absolute.path;
    final baseName = file.uri.pathSegments.isNotEmpty
        ? file.uri.pathSegments.last
        : absolutePath;

    return AudioTrack(
      id: '$absolutePath#$index',
      uri: absolutePath,
      title: baseName,
    );
  }, growable: false);
}

Future<void> _waitFor({
  required String description,
  required bool Function() condition,
  Duration timeout = const Duration(seconds: 12),
  Duration step = const Duration(milliseconds: 100),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) {
      return;
    }
    await Future<void>.delayed(step);
  }

  throw TestFailure('Timed out waiting for $description.');
}

Duration _seekTargetFor(Duration duration) {
  final maxTarget = duration - const Duration(seconds: 5);
  if (maxTarget <= const Duration(seconds: 5)) {
    return const Duration(seconds: 1);
  }
  if (maxTarget >= const Duration(seconds: 20)) {
    return const Duration(seconds: 20);
  }
  return Duration(milliseconds: maxTarget.inMilliseconds ~/ 2);
}

bool _closeTo(
  Duration actual,
  Duration expected, {
  Duration tolerance = const Duration(milliseconds: 1500),
}) {
  return (actual - expected).abs() <= tolerance;
}
