import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'palette/palette_generator.dart' as original_palette;

const int _decodedImageWidth = 300;
const int _decodedImageHeight = 300;
const int _rawRgbChannels = 3;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('palette.rs matches the original palette algorithm on decoded images', () async {
    final rawDir = _resolveExistingDirectory(const <String>[
      '../test/decoed_imgs',
      'test/decoed_imgs',
    ]);
    final rustDir = _resolveExistingDirectory(const <String>['../rust', 'rust']);
    final rawFiles = _discoverRawFiles(rawDir);
    final actualByFile = await _generateRustThemeColors(rawDir, rustDir);
    final mismatches = <String>[];

    for (final rawFile in rawFiles) {
      final fileName = rawFile.uri.pathSegments.last;
      final actualThemeColors = actualByFile[fileName];
      if (actualThemeColors == null) {
        mismatches.add('Rust result is missing $fileName');
        continue;
      }

      final expectedThemeColors = await _generateOriginalThemeColors(rawFile);
      final diff = _compareThemeColors(
        label: rawFile.path,
        actualThemeColors: actualThemeColors,
        expectedThemeColors: expectedThemeColors,
      );
      if (diff != null) {
        mismatches.add(diff);
      }
    }

    expect(mismatches, isEmpty, reason: mismatches.join('\n\n'));
  });
}

Future<Map<String, Map<String, int>>> _generateRustThemeColors(
  Directory rawDir,
  Directory rustDir,
) async {
  final result = await Process.run('cargo', <String>[
    'run',
    '--quiet',
    '--bin',
    'palette_parity',
    '--',
    rawDir.path,
  ], workingDirectory: rustDir.path);

  if (result.exitCode != 0) {
    throw StateError(
      'Failed to run palette parity helper.\n'
      'exitCode=${result.exitCode}\n'
      'stdout=${result.stdout}\n'
      'stderr=${result.stderr}',
    );
  }

  final decoded = jsonDecode(result.stdout as String);
  if (decoded is! Map) {
    throw StateError('Unexpected Rust palette output: $decoded');
  }

  return decoded.map<String, Map<String, int>>((key, value) {
    if (value is! Map) {
      throw StateError('Unexpected palette map for $key: $value');
    }

    final themeColors = value.map<String, int>((themeKey, themeValue) {
      if (themeValue is! num) {
        throw StateError(
          'Unexpected palette value for "$themeKey" in "$key": $themeValue',
        );
      }
      return MapEntry(themeKey.toString(), themeValue.toInt());
    });
    return MapEntry(key.toString(), themeColors);
  });
}

Future<Map<String, int>> _generateOriginalThemeColors(File rawFile) async {
  final encodedImage = await _readEncodedImageFromRawFile(rawFile);
  final palette = await original_palette.PaletteGenerator.fromByteData(
    encodedImage,
  );
  return _themeColorsFromPalette(palette);
}

Future<original_palette.EncodedImage> _readEncodedImageFromRawFile(
  File rawFile,
) async {
  final rawBytes = await rawFile.readAsBytes();
  final expectedLength =
      _decodedImageWidth * _decodedImageHeight * _rawRgbChannels;
  expect(
    rawBytes.length,
    expectedLength,
    reason: 'Unexpected raw RGB length for ${rawFile.path}',
  );

  final rgbaBytes =
      Uint8List(_decodedImageWidth * _decodedImageHeight * 4);
  for (int src = 0, dst = 0; src < rawBytes.length; src += 3, dst += 4) {
    rgbaBytes[dst] = rawBytes[src];
    rgbaBytes[dst + 1] = rawBytes[src + 1];
    rgbaBytes[dst + 2] = rawBytes[src + 2];
    rgbaBytes[dst + 3] = 0xff;
  }

  final byteData = ByteData.sublistView(rgbaBytes);
  return original_palette.EncodedImage(
    byteData,
    width: _decodedImageWidth,
    height: _decodedImageHeight,
  );
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

String? _compareThemeColors({
  required String label,
  required Map<String, int> actualThemeColors,
  required Map<String, int> expectedThemeColors,
}) {
  final actualKeys = actualThemeColors.keys.toSet();
  final expectedKeys = expectedThemeColors.keys.toSet();
  if (actualKeys.length != expectedKeys.length ||
      !actualKeys.containsAll(expectedKeys) ||
      !expectedKeys.containsAll(actualKeys)) {
    return [
      'Theme color keys differ for $label',
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
    'Theme color mismatch for $label',
    ...differences,
    'Actual map: $actualThemeColors',
    'Expected map: $expectedThemeColors',
  ].join('\n');
}

List<File> _discoverRawFiles(Directory directory) {
  final rawFiles =
      directory
          .listSync()
          .whereType<File>()
          .where((file) => file.path.toLowerCase().endsWith('.raw'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  if (rawFiles.isEmpty) {
    throw StateError('No raw images found in ${directory.path}.');
  }

  return rawFiles;
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
