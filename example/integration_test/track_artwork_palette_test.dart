import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:audio_core/audio_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'palette/palette_generator.dart' as original_palette;

const int _paletteMaxColors = 20;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  test('generateTrackArtwork matches the original palette algorithm', () async {
    final mismatches = <String>[];

    for (final imageFile in _discoverTestImages()) {
      final diff = await _compareThemeColors(imageFile);
      if (diff != null) {
        mismatches.add(diff);
      }
    }

    expect(mismatches, isEmpty, reason: mismatches.join('\n\n'));
  });
}

Future<Map<String, int>> _generateRustThemeColors(File imageFile) async {
  final tempDir = await Directory.systemTemp.createTemp('audio_core_palette_');
  addTearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  final sampleAudioSource = _resolveExistingFile(const <String>[
    'rust/lofty-rs/tests/files/assets/minimal/full_test.mp3',
    'rust/lofty-rs/tests/taglib/data/bladeenc.mp3',
    'android/src/main/cpp/chromaprint/tests/data/test.mp3',
  ]);

  final tempAudio = File('${tempDir.path}${Platform.pathSeparator}sample.mp3');
  await sampleAudioSource.copy(tempAudio.path);

  await removeAllTags(path: tempAudio.path);
  await updateTrackMetadata(
    path: tempAudio.path,
    metadata: TrackMetadataUpdate(
      genres: const <String>[],
      pictures: <TrackPicture>[
        TrackPicture(
          bytes: await imageFile.readAsBytes(),
          mimeType: 'image/jpeg',
          pictureType: 'Front Cover',
        ),
      ],
    ),
  );

  final cacheRoot = Directory('${tempDir.path}${Platform.pathSeparator}cache');
  await cacheRoot.create(recursive: true);

  final result = await generateTrackArtwork(
    path: tempAudio.path,
    cacheRootPath: cacheRoot.path,
    saveLargeArtwork: false,
    thumbnailSize: generatedArtworkThumbnailSize,
  );

  expect(
    result.artworkFound,
    isTrue,
    reason: 'Expected embedded artwork to be written for ${imageFile.path}',
  );
  expect(
    result.themeColorsBlob,
    isNotNull,
    reason: 'Expected theme colors blob for ${imageFile.path}',
  );

  return _decodeThemeColorsBlob(result.themeColorsBlob!);
}

Future<Map<String, int>> _generateOriginalThemeColors(File imageFile) async {
  final encodedImage = await _readEncodedImage(imageFile);
  final palette = await original_palette.PaletteGenerator.fromByteData(
    encodedImage,
    maximumColorCount: _paletteMaxColors,
  );
  return _themeColorsFromPalette(palette);
}

Future<original_palette.EncodedImage> _readEncodedImage(File imageFile) async {
  final bytes = await imageFile.readAsBytes();
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final thumbnail = await _buildSquareThumbnail(
    frame.image,
    generatedArtworkThumbnailSize,
  );
  final byteData = await thumbnail.toByteData(
    format: ui.ImageByteFormat.rawRgba,
  );
  frame.image.dispose();
  thumbnail.dispose();

  expect(
    byteData,
    isNotNull,
    reason: 'Failed to decode ${imageFile.path} into raw RGBA bytes',
  );

  return original_palette.EncodedImage(
    byteData!,
    width: generatedArtworkThumbnailSize,
    height: generatedArtworkThumbnailSize,
  );
}

Future<ui.Image> _buildSquareThumbnail(ui.Image source, int size) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  final paint = ui.Paint()..filterQuality = ui.FilterQuality.high;

  final cropSize = math.min(source.width, source.height).toDouble();
  final offsetX = (source.width - cropSize) / 2.0;
  final offsetY = (source.height - cropSize) / 2.0;
  final sourceRect = ui.Rect.fromLTWH(offsetX, offsetY, cropSize, cropSize);
  final targetRect = ui.Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble());

  canvas.drawImageRect(source, sourceRect, targetRect, paint);
  final picture = recorder.endRecording();
  return picture.toImage(size, size);
}

Map<String, int> _themeColorsFromPalette(
  original_palette.PaletteGenerator palette,
) {
  final themeColors = <String, int>{};

  void addColor(String key, original_palette.PaletteColor? color) {
    if (color != null) {
      themeColors[key] = color.color.value;
    }
  }

  addColor('dominant', palette.dominantColor);
  addColor('lightVibrant', palette.lightVibrantColor);
  addColor('vibrant', palette.vibrantColor);
  addColor('darkVibrant', palette.darkVibrantColor);
  addColor('lightMuted', palette.lightMutedColor);
  addColor('muted', palette.mutedColor);
  addColor('darkMuted', palette.darkMutedColor);

  return themeColors;
}

Future<String?> _compareThemeColors(File imageFile) async {
  final actualThemeColors = await _generateRustThemeColors(imageFile);
  final expectedThemeColors = await _generateOriginalThemeColors(imageFile);

  final actualKeys = actualThemeColors.keys.toSet();
  final expectedKeys = expectedThemeColors.keys.toSet();
  if (actualKeys.length != expectedKeys.length ||
      !actualKeys.containsAll(expectedKeys) ||
      !expectedKeys.containsAll(actualKeys)) {
    return [
      'Theme color keys differ for ${imageFile.path}',
      'Actual keys: $actualKeys',
      'Expected keys: $expectedKeys',
      'Actual map: $actualThemeColors',
      'Expected map: $expectedThemeColors',
    ].join('\n');
  }

  final differences = <String>[];
  for (final key in expectedThemeColors.keys) {
    final actual = actualThemeColors[key];
    final expected = expectedThemeColors[key];
    if (actual != expected) {
      differences.add('  $key: actual=$actual expected=$expected');
    }
  }

  if (differences.isEmpty) {
    return null;
  }

  return [
    'Theme color mismatch for ${imageFile.path}',
    ...differences,
    'Actual map: $actualThemeColors',
    'Expected map: $expectedThemeColors',
  ].join('\n');
}

Map<String, int> _decodeThemeColorsBlob(Uint8List blob) {
  final decoded = jsonDecode(utf8.decode(blob));
  if (decoded is! Map) {
    throw StateError('Unexpected theme colors blob format: $decoded');
  }

  return decoded.map<String, int>((key, value) {
    if (value is! num) {
      throw StateError(
        'Unexpected value for "$key" in theme colors blob: $value',
      );
    }
    return MapEntry(key.toString(), value.toInt());
  });
}

List<File> _discoverTestImages() {
  final directory = _resolveExistingDirectory(const <String>['test/test_imgs']);

  final images =
      directory
          .listSync()
          .whereType<File>()
          .where(
            (file) =>
                file.path.toLowerCase().endsWith('.jpg') ||
                file.path.toLowerCase().endsWith('.jpeg'),
          )
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  if (images.isEmpty) {
    throw StateError('No test images found in ${directory.path}.');
  }

  return images;
}

Directory _resolveExistingDirectory(List<String> relativePaths) {
  for (final root in _candidateRoots()) {
    for (final relativePath in relativePaths) {
      final directory = Directory(_joinPath(root, relativePath));
      if (directory.existsSync()) {
        return directory;
      }
    }
  }

  throw StateError('Unable to locate any of these directories: $relativePaths');
}

File _resolveExistingFile(List<String> relativePaths) {
  for (final root in _candidateRoots()) {
    for (final relativePath in relativePaths) {
      final file = File(_joinPath(root, relativePath));
      if (file.existsSync()) {
        return file;
      }
    }
  }

  throw StateError('Unable to locate any of these files: $relativePaths');
}

Iterable<String> _candidateRoots() sync* {
  yield Directory.current.path;
  yield Directory.current.parent.path;
  yield Directory.current.parent.parent.path;
}

String _joinPath(String root, String relativePath) {
  final normalizedRelative = relativePath.replaceAll(
    '/',
    Platform.pathSeparator,
  );
  return '$root${Platform.pathSeparator}$normalizedRelative';
}
