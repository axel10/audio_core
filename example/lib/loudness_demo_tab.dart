import 'dart:io';
import 'dart:math' as math;

import 'package:audio_core/audio_core.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

class LoudnessDemoTab extends StatefulWidget {
  const LoudnessDemoTab({super.key, required this.controller});

  final AudioCoreController controller;

  @override
  State<LoudnessDemoTab> createState() => _LoudnessDemoTabState();
}

class _LoudnessDemoTabState extends State<LoudnessDemoTab> {
  final List<String> _selectedPaths = [];
  List<TrackLoudnessResult> _trackResults = [];
  AlbumLoudnessResult? _albumResult;

  double _targetLufs = -18.0;
  bool _clippingProtection = true;
  bool _busy = false;
  String? _status;
  String? _error;

  Future<void> _pickFiles() async {
    final result = await FilePicker.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: const [
        'flac',
        'mp3',
        'm4a',
        'aac',
        'wav',
        'ogg',
        'opus',
        'alac',
      ],
    );
    if (result == null) return;

    final paths = result.paths.whereType<String>().toList()..sort();
    if (paths.isEmpty) return;

    setState(() {
      _selectedPaths
        ..clear()
        ..addAll(paths);
      _trackResults = [];
      _albumResult = null;
      _error = null;
      _status = 'Selected ${paths.length} file(s)';
    });
  }

  Future<void> _pickDirectory() async {
    final dirPath = await FilePicker.getDirectoryPath();
    if (dirPath == null) return;

    final dir = Directory(dirPath);
    if (!await dir.exists()) return;

    const exts = {
      '.flac',
      '.mp3',
      '.m4a',
      '.aac',
      '.wav',
      '.ogg',
      '.opus',
      '.alac',
    };

    final files = await dir
        .list(followLinks: false)
        .where((entity) => entity is File)
        .map((entity) => entity.path)
        .where((path) {
          final name = p.basename(path);
          if (name.startsWith('._')) return false;
          return exts.contains(p.extension(path).toLowerCase());
        })
        .toList();
    files.sort();

    setState(() {
      _selectedPaths
        ..clear()
        ..addAll(files);
      _trackResults = [];
      _albumResult = null;
      _error = null;
      _status = 'Loaded ${files.length} file(s) from ${p.basename(dirPath)}';
    });
  }

  Future<void> _analyzeTracks() async {
    if (_selectedPaths.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _trackResults = [];
      _albumResult = null;
      _status = 'Analyzing ${_selectedPaths.length} track(s) individually...';
    });

    try {
      final results = <TrackLoudnessResult>[];
      for (var i = 0; i < _selectedPaths.length; i++) {
        final path = _selectedPaths[i];
        setState(() {
          _status =
              'Analyzing ${i + 1}/${_selectedPaths.length}: ${p.basename(path)}';
        });
        final res = await analyzeTrackLoudness(path: path);
        results.add(res);
      }
      if (!mounted) return;
      setState(() {
        _trackResults = results;
        _status = 'Track analysis finished (${results.length} track(s))';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _status = 'Track analysis failed';
      });
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _analyzeAlbum() async {
    if (_selectedPaths.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _trackResults = [];
      _albumResult = null;
      _status = 'Analyzing album (${_selectedPaths.length} track(s))...';
    });

    try {
      final res = await analyzeAlbumLoudness(paths: _selectedPaths);
      if (!mounted) return;
      setState(() {
        _albumResult = res;
        _trackResults = res.tracks;
        _status =
            'Album analysis finished in ${res.totalElapsedMs} ms';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _status = 'Album analysis failed';
      });
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  double _computeGainDb(double lufs, double peak) {
    final rawGain = _targetLufs - lufs;
    if (!_clippingProtection || peak <= 0) {
      return rawGain;
    }
    final peakDb = 20.0 * (math.log(peak) / math.ln10);
    const maxPeakDb = -1.0;
    final maxAllowedGain = maxPeakDb - peakDb;
    return math.min(rawGain, maxAllowedGain);
  }

  Future<void> _playWithGain(String path, double gainDb) async {
    try {
      await widget.controller.equalizer.setPreamp(gainDb);
      await widget.controller.playPaths([path]);
      if (!mounted) return;
      setState(() {
        _status =
            'Playing ${p.basename(path)} with preamp ${gainDb.toStringAsFixed(2)} dB';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Playback error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final album = _albumResult;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ElevatedButton.icon(
                onPressed: _busy ? null : _pickFiles,
                icon: const Icon(Icons.audio_file),
                label: const Text('Pick Audio Files'),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : _pickDirectory,
                icon: const Icon(Icons.folder_open),
                label: const Text('Pick Album Folder'),
              ),
              FilledButton.icon(
                onPressed:
                    (_busy || _selectedPaths.isEmpty) ? null : _analyzeTracks,
                icon: const Icon(Icons.analytics_outlined),
                label: const Text('Analyze Tracks'),
              ),
              FilledButton.tonalIcon(
                onPressed:
                    (_busy || _selectedPaths.isEmpty) ? null : _analyzeAlbum,
                icon: const Icon(Icons.album),
                label: const Text('Analyze Album'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text('Target Loudness: '),
                      const SizedBox(width: 8),
                      SegmentedButton<double>(
                        segments: const [
                          ButtonSegment(value: -18.0, label: Text('-18 LUFS')),
                          ButtonSegment(value: -16.0, label: Text('-16 LUFS')),
                          ButtonSegment(value: -14.0, label: Text('-14 LUFS')),
                        ],
                        selected: {_targetLufs},
                        onSelectionChanged: (v) {
                          setState(() => _targetLufs = v.first);
                        },
                      ),
                    ],
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('True Peak Clipping Protection (-1.0 dBTP)'),
                    value: _clippingProtection,
                    onChanged: (v) => setState(() => _clippingProtection = v),
                  ),
                  if (_status != null)
                    Text(
                      _status!,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (album != null) ...[
            const SizedBox(height: 12),
            Card(
              color: Theme.of(context).colorScheme.secondaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Album Summary (${album.tracks.length} tracks)',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Album LUFS: ${album.albumLufs.toStringAsFixed(2)} LUFS | '
                      'Recommended Gain: ${_computeGainDb(album.albumLufs, album.albumTruePeak).toStringAsFixed(2)} dB | '
                      'True Peak: ${album.albumTruePeak.toStringAsFixed(6)} (${album.albumTruePeakDbtp.toStringAsFixed(2)} dBTP) | '
                      'Elapsed: ${album.totalElapsedMs} ms',
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          if (_trackResults.isEmpty && _selectedPaths.isNotEmpty)
            ..._selectedPaths.map(
              (path) => ListTile(
                dense: true,
                leading: const Icon(Icons.music_note),
                title: Text(p.basename(path)),
                subtitle: Text(path),
              ),
            )
          else
            ..._trackResults.map((track) {
              final gain = _computeGainDb(track.loudnessLufs, track.truePeak);
              final rawGain = _targetLufs - track.loudnessLufs;
              final clipped = _clippingProtection && gain < rawGain - 0.001;
              return Card(
                child: ListTile(
                  title: Text(p.basename(track.path)),
                  subtitle: Text(
                    'LUFS: ${track.loudnessLufs.toStringAsFixed(2)} | '
                    'Gain: ${gain.toStringAsFixed(2)} dB${clipped ? ' (clip-limited)' : ''} | '
                    'True Peak: ${track.truePeak.toStringAsFixed(6)} (${track.truePeakDbtp.toStringAsFixed(2)} dBTP)\n'
                    '${track.sampleRate} Hz / ${track.channels} ch / ${track.elapsedMs} ms',
                  ),
                  trailing: IconButton(
                    tooltip: 'Play with computed gain',
                    icon: const Icon(Icons.play_arrow),
                    onPressed: () => _playWithGain(track.path, gain),
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }
}
