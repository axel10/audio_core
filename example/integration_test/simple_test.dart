import 'dart:io';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:audio_core/audio_core.dart';
import 'package:flutter/services.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => await RustLib.init());

  test('Can call rust function', () async {
    expect(greet(name: "Tom"), "Hello, Tom!");
  });

  test('Can convert file using system encoder on Android', () async {
    if (!Platform.isAndroid) {
      return;
    }

    final audioConverter = AudioConverter();

    // 1. Extract asset to temporary file
    const assetPath = 'assets/test_music/01 Summer drop.m4a';
    final bytes = await rootBundle.load(assetPath);
    final targetDirectory = await Directory.systemTemp.createTemp('audio_core_transcode_test_');
    final inputFile = File('${targetDirectory.path}/input.m4a');
    await inputFile.writeAsBytes(bytes.buffer.asUint8List(), flush: true);

    final outputFile = File('${targetDirectory.path}/output.m4a');

    // 2. Perform transcoding using system encoder
    final request = ConvertRequest(
      inputPath: inputFile.path,
      outputPath: outputFile.path,
      outputFormat: AudioFormat.m4a,
      useSystemEncoder: true,
    );

    final result = await audioConverter.convertFile(
      request,
      onProgress: (progress) {
        print('Transcode progress: ${progress.message} - ${progress.currentFileProgress}');
      },
    );

    expect(result.success, isTrue);
    expect(result.outputPath, equals(outputFile.path));
    expect(outputFile.existsSync(), isTrue);
    expect(outputFile.lengthSync(), greaterThan(0));

    // Cleanup
    await targetDirectory.delete(recursive: true);
  });
}
