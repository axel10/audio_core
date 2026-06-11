import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_taglib/flutter_taglib.dart' as taglib;

import 'package:audio_core/src/audio_engine/flutter_taglib_metadata_bridge.dart';

void main() {
  group('flutter_taglib metadata bridge', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync(
        'flutter_taglib_metadata_bridge_test',
      );
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('writing a year only does not also persist a duplicate DATE field', () async {
      final source = File(
        'flutter_taglib/test/assets/01 TempleOS Hymn Risen (Remix).mp3',
      );
      final target = File('${tempDir.path}/year_only.mp3');
      source.copySync(target.path);

      final success = await updateTrackMetadataWithFlutterTaglib(
        path: target.path,
        metadata: const <String, Object?>{
          'year': 2023,
          'clearBeforeWrite': true,
        },
      );

      expect(success, isTrue);

      final file = taglib.TagLibFile.open(target.path);
      expect(file, isNotNull);
      expect(file!.properties[taglib.TagProperties.year], equals(['2023']));
      expect(file.properties.containsKey(taglib.TagProperties.date), isFalse);
      file.close();
    });
  });
}
