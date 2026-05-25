import 'dart:io';

import 'package:audio_core/audio_core.dart';
import 'package:flutter/material.dart';

class TranscodeTab extends StatefulWidget {
  const TranscodeTab({super.key, required this.audioConverter});

  final AudioConverter audioConverter;

  @override
  State<TranscodeTab> createState() => _TranscodeTabState();
}

class _TranscodeTabState extends State<TranscodeTab> {
  AudioFormat _outputFormat = AudioFormat.m4a;
  bool _useSystemEncoder = false;
  ConverterCapabilities? _capabilities;
  String? _inputPath;
  String? _outputDirectory;
  AndroidOutputDirectory? _androidDirectory;
  ConversionProgress? _progress;
  ConvertResult? _result;
  String? _status;
  bool _busy = false;
  BitRateMode _bitRateMode = BitRateMode.vbr;
  int _bitRate = 192000;
  AacEncoder _aacEncoder = AacEncoder.ffmpeg;

  bool get _supportsBitRate => switch (_outputFormat) {
        AudioFormat.alac ||
        AudioFormat.aiff ||
        AudioFormat.flac ||
        AudioFormat.wav =>
          false,
        _ => true,
      };

  @override
  void initState() {
    super.initState();
    _loadCapabilities();
  }

  Future<void> _loadCapabilities() async {
    try {
      final capabilities = await widget.audioConverter.getCapabilities();
      if (!mounted) return;
      setState(() {
        _capabilities = capabilities;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _status = 'Failed to read capabilities: $error';
      });
    }
  }

  Future<void> _pickInputFile() async {
    final path = await widget.audioConverter.pickInputFile();
    if (!mounted) return;
    setState(() {
      _inputPath = path;
      _result = null;
      _progress = null;
      _status = path == null ? 'Input selection cancelled.' : null;
    });
  }

  Future<void> _pickOutputDirectory() async {
    if (Platform.isAndroid) {
      final directory = await widget.audioConverter
          .pickAndroidOutputDirectory();
      if (!mounted) return;
      setState(() {
        _androidDirectory = directory;
        _outputDirectory = directory?.displayPath;
        _status = directory == null
            ? 'Android output selection cancelled.'
            : null;
      });
      return;
    }

    final directory = await widget.audioConverter.pickOutputDirectory();
    if (!mounted) return;
    setState(() {
      _outputDirectory = directory;
      _androidDirectory = null;
      _status = directory == null ? 'Output selection cancelled.' : null;
    });
  }

  Future<void> _startConversion() async {
    final inputPath = _inputPath;
    if (inputPath == null || inputPath.isEmpty) {
      setState(() {
        _status = 'Please pick an input file first.';
      });
      return;
    }

    setState(() {
      _busy = true;
      _result = null;
      _progress = null;
      _status = 'Starting conversion...';
    });

    try {
      final hasAacEncoder = _supportsBitRate &&
          !_useSystemEncoder &&
          !(Platform.isIOS || Platform.isMacOS);

      if (Platform.isAndroid && _androidDirectory != null) {
        final result = await widget.audioConverter
            .convertAndSaveToAndroidDirectory(
              ConvertRequest.forOutputDirectory(
                inputPath: inputPath,
                outputDirectory: _androidDirectory!.displayPath,
                outputFormat: _outputFormat,
                useSystemEncoder: _useSystemEncoder,
                bitRate: _supportsBitRate ? _bitRate : null,
                bitRateMode: _supportsBitRate ? _bitRateMode : null,
                aacEncoder: hasAacEncoder ? _aacEncoder : null,
              ),
              _androidDirectory!,
              onProgress: (progress) {
                if (!mounted) return;
                setState(() {
                  _progress = progress;
                });
              },
            );

        if (!mounted) return;
        setState(() {
          _result = result.conversionResult;
          _status = result.success
              ? 'Saved to ${result.outputPath ?? '(unknown)'}'
              : result.errorMessage;
        });
      } else {
        final outputDirectory = _outputDirectory;
        if (outputDirectory == null || outputDirectory.isEmpty) {
          setState(() {
            _status = 'Please pick an output directory first.';
          });
          return;
        }

        final result = await widget.audioConverter.convertToOutputDirectory(
          inputPath: inputPath,
          outputDirectory: outputDirectory,
          outputFormat: _outputFormat,
          useSystemEncoder: _useSystemEncoder,
          bitRate: _supportsBitRate ? _bitRate : null,
          bitRateMode: _supportsBitRate ? _bitRateMode : null,
          aacEncoder: hasAacEncoder ? _aacEncoder : null,
          onProgress: (progress) {
            if (!mounted) return;
            setState(() {
              _progress = progress;
            });
          },
        );

        if (!mounted) return;
        setState(() {
          _result = result;
          _status = result.success
              ? 'Output created at ${result.outputPath ?? '(unknown)'}'
              : result.errorMessage;
        });
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _status = 'Conversion failed: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final capabilities = _capabilities;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Transcode Demo',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(
            'This tab drives the audio_converter plugin through the audio_core package export.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          _buildCard(
            context,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Capabilities',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text('Engine: ${capabilities?.engine ?? 'loading...'}'),
                Text(
                  'Formats: ${capabilities == null ? 'loading...' : capabilities.supportedOutputFormats.map((format) => format.value).join(', ')}',
                ),
                if (capabilities?.notes != null) ...[
                  const SizedBox(height: 8),
                  Text(capabilities!.notes!),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          _buildCard(
            context,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Source', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                SelectableText(_inputPath ?? 'No input selected'),
                const SizedBox(height: 8),
                ElevatedButton.icon(
                  onPressed: _busy ? null : _pickInputFile,
                  icon: const Icon(Icons.audio_file),
                  label: const Text('Pick Input File'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _buildCard(
            context,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Output', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                DropdownButtonFormField<AudioFormat>(
                  decoration: const InputDecoration(
                    labelText: 'Output format',
                    border: OutlineInputBorder(),
                  ),
                  items: AudioFormat.values
                      .map(
                        (format) => DropdownMenuItem(
                          value: format,
                          child: Text(format.value.toUpperCase()),
                        ),
                      )
                      .toList(growable: false),
                  initialValue: _outputFormat,
                  onChanged: _busy
                      ? null
                      : (value) {
                          if (value == null) return;
                          setState(() {
                            _outputFormat = value;
                            if (_outputFormat != AudioFormat.m4a) {
                              _useSystemEncoder = false;
                            }
                          });
                        },
                ),
                if (Platform.isAndroid && _outputFormat == AudioFormat.m4a) ...[
                  const SizedBox(height: 8),
                  DropdownButtonFormField<bool>(
                    decoration: const InputDecoration(
                      labelText: 'Encoding Engine',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: false,
                        child: Text('FFmpeg (Rust)'),
                      ),
                      DropdownMenuItem(
                        value: true,
                        child: Text('Media3 (System)'),
                      ),
                    ],
                    initialValue: _useSystemEncoder,
                    onChanged: _busy
                        ? null
                        : (value) {
                            if (value == null) return;
                            setState(() {
                              _useSystemEncoder = value;
                            });
                          },
                  ),
                ],
                if (_supportsBitRate) ...[
                  const SizedBox(height: 8),
                  DropdownButtonFormField<BitRateMode>(
                    decoration: const InputDecoration(
                      labelText: 'Bitrate Mode',
                      border: OutlineInputBorder(),
                    ),
                    items: BitRateMode.values
                        .map(
                          (mode) => DropdownMenuItem(
                            value: mode,
                            child: Text(mode == BitRateMode.cbr ? 'CBR' : 'VBR'),
                          ),
                        )
                        .toList(),
                    initialValue: _bitRateMode,
                    onChanged: _busy
                        ? null
                        : (value) {
                            if (value == null) return;
                            setState(() {
                              _bitRateMode = value;
                            });
                          },
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<int>(
                    decoration: const InputDecoration(
                      labelText: 'Bitrate',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(value: 128000, child: Text('128 kbps')),
                      DropdownMenuItem(value: 192000, child: Text('192 kbps')),
                      DropdownMenuItem(value: 256000, child: Text('256 kbps')),
                      DropdownMenuItem(value: 320000, child: Text('320 kbps')),
                    ],
                    initialValue: _bitRate,
                    onChanged: _busy
                        ? null
                        : (value) {
                            if (value == null) return;
                            setState(() {
                              _bitRate = value;
                            });
                          },
                  ),
                  if (!(Platform.isIOS || Platform.isMacOS) &&
                      !_useSystemEncoder &&
                      (_outputFormat == AudioFormat.aac ||
                          _outputFormat == AudioFormat.m4a ||
                          _outputFormat == AudioFormat.m4b ||
                          _outputFormat == AudioFormat.caf)) ...[
                    const SizedBox(height: 8),
                    DropdownButtonFormField<AacEncoder>(
                      decoration: const InputDecoration(
                        labelText: 'AAC Encoder',
                        border: OutlineInputBorder(),
                      ),
                      items: AacEncoder.values
                          .map(
                            (enc) => DropdownMenuItem(
                              value: enc,
                              child: Text(enc.label),
                            ),
                          )
                          .toList(),
                      initialValue: _aacEncoder,
                      onChanged: _busy
                          ? null
                          : (value) {
                              if (value == null) return;
                              setState(() {
                                _aacEncoder = value;
                              });
                            },
                    ),
                  ],
                ],
                const SizedBox(height: 8),
                Text(_outputDirectory ?? 'No output directory selected'),
                if (_androidDirectory != null) ...[
                  const SizedBox(height: 4),
                  Text('Android tree: ${_androidDirectory!.treeUri}'),
                ],
                const SizedBox(height: 8),
                ElevatedButton.icon(
                  onPressed: _busy ? null : _pickOutputDirectory,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Pick Output Directory'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _buildCard(
            context,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Run', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                ElevatedButton.icon(
                  onPressed: _busy ? null : _startConversion,
                  icon: const Icon(Icons.transform),
                  label: Text(_busy ? 'Converting...' : 'Start Transcode'),
                ),
                const SizedBox(height: 12),
                if (_progress != null) ...[
                  LinearProgressIndicator(value: _progress!.overallProgress),
                  const SizedBox(height: 8),
                  Text(
                    '${(_progress!.overallProgress ?? 0).toStringAsFixed(2)} '
                    ' | ${_progress!.currentFileProgress?.toStringAsFixed(2) ?? 'n/a'}',
                  ),
                  Text('Current file: ${_progress!.currentFilePath}'),
                  if (_progress!.message != null) Text(_progress!.message!),
                ] else
                  const Text('No progress yet.'),
                const SizedBox(height: 12),
                Text(_status ?? 'Ready.'),
                if (_result != null) ...[
                  const SizedBox(height: 12),
                  Text('Success: ${_result!.success}'),
                  Text('Engine: ${_result!.engine ?? 'n/a'}'),
                  Text('Output: ${_result!.outputPath ?? 'n/a'}'),
                  if (_result!.errorMessage != null)
                    Text('Error: ${_result!.errorMessage}'),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCard(BuildContext context, {required Widget child}) {
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    );
  }
}
