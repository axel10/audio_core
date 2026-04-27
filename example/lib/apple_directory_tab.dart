import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

class AppleMusicFileEntry {
  AppleMusicFileEntry({required this.path, required this.relativePath});

  final String path;
  final String relativePath;

  String get fileName => Uri.file(path).pathSegments.last;
  String get extension {
    final name = fileName;
    final index = name.lastIndexOf('.');
    if (index < 0 || index == name.length - 1) {
      return '';
    }
    return name.substring(index + 1).toLowerCase();
  }
}

class AppleDirectoryTab extends StatefulWidget {
  const AppleDirectoryTab({super.key});

  @override
  State<AppleDirectoryTab> createState() => _AppleDirectoryTabState();
}

class _AppleDirectoryTabState extends State<AppleDirectoryTab> {
  static const List<String> _audioFileExtensions = <String>[
    'aac',
    'aif',
    'aiff',
    'alac',
    'caf',
    'flac',
    'm4a',
    'm4b',
    'm4p',
    'mid',
    'midi',
    'mp3',
    'ogg',
    'opus',
    'wav',
    'webm',
  ];

  bool _isScanning = false;
  String? _selectedDirectory;
  String? _errorMessage;
  DateTime? _lastScannedAt;
  List<AppleMusicFileEntry> _files = <AppleMusicFileEntry>[];

  bool get _isApplePlatform => Platform.isIOS || Platform.isMacOS;

  Future<void> _pickDirectory() async {
    if (!_isApplePlatform) {
      setState(() {
        _errorMessage = 'This demo is intended for iOS and macOS.';
      });
      return;
    }

    String? selected;
    try {
      selected = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Choose a music directory',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Directory picker failed: $e';
      });
      return;
    }
    if (!mounted || selected == null || selected.isEmpty) {
      return;
    }

    setState(() {
      _selectedDirectory = selected;
      _isScanning = true;
      _errorMessage = null;
      _files = <AppleMusicFileEntry>[];
      _lastScannedAt = null;
    });

    try {
      final files = await _scanMusicFiles(selected);
      if (!mounted) return;
      setState(() {
        _files = files;
        _isScanning = false;
        _lastScannedAt = DateTime.now();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isScanning = false;
        _errorMessage = e.toString();
      });
    }
  }

  Future<List<AppleMusicFileEntry>> _scanMusicFiles(
    String directoryPath,
  ) async {
    final root = Directory(directoryPath);
    if (!await root.exists()) {
      throw StateError('Directory does not exist: $directoryPath');
    }

    final normalizedRoot = _normalizeDirectoryPath(directoryPath);
    final results = <AppleMusicFileEntry>[];

    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final extension = _extensionForPath(entity.path);
      if (!_audioFileExtensions.contains(extension)) continue;
      results.add(
        AppleMusicFileEntry(
          path: entity.path,
          relativePath: _relativePath(normalizedRoot, entity.path),
        ),
      );
    }

    results.sort(
      (a, b) =>
          a.relativePath.toLowerCase().compareTo(b.relativePath.toLowerCase()),
    );
    return results;
  }

  String _relativePath(String rootPath, String filePath) {
    final normalizedRoot = _normalizeDirectoryPath(rootPath);
    final normalizedFile = _normalizeDirectoryPath(filePath);
    if (normalizedFile == normalizedRoot) {
      return Uri.file(filePath).pathSegments.last;
    }
    final prefix = '$normalizedRoot/';
    if (normalizedFile.startsWith(prefix)) {
      return normalizedFile.substring(prefix.length);
    }
    return filePath;
  }

  String _normalizeDirectoryPath(String path) {
    final cleaned = path.replaceAll('\\', '/').trim();
    if (cleaned.isEmpty) return cleaned;
    return cleaned.endsWith('/')
        ? cleaned.substring(0, cleaned.length - 1)
        : cleaned;
  }

  String _extensionForPath(String path) {
    final name = Uri.file(path).pathSegments.last;
    final index = name.lastIndexOf('.');
    if (index < 0 || index == name.length - 1) {
      return '';
    }
    return name.substring(index + 1).toLowerCase();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Apple Directory',
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Pick a folder and scan audio files recursively.',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
              ElevatedButton.icon(
                onPressed: _isScanning ? null : _pickDirectory,
                icon: const Icon(Icons.folder_open),
                label: Text(_isScanning ? 'Scanning...' : 'Choose Folder'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_selectedDirectory != null) ...[
            Text(
              _selectedDirectory!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
          ],
          if (_lastScannedAt != null)
            Text(
              'Found ${_files.length} music files. Last scanned at ${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(_lastScannedAt!))}.',
              style: theme.textTheme.bodySmall,
            ),
          if (_errorMessage != null) ...[
            const SizedBox(height: 8),
            Text(
              _errorMessage!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: _isScanning
                  ? const Center(child: CircularProgressIndicator())
                  : _files.isEmpty
                  ? Center(
                      child: Text(
                        _selectedDirectory == null
                            ? 'Choose a folder to start scanning.'
                            : 'No music files found in this folder.',
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(12),
                      itemCount: _files.length,
                      separatorBuilder: (context, index) =>
                          const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final entry = _files[index];
                        return Card(
                          elevation: 0,
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor:
                                  theme.colorScheme.primaryContainer,
                              child: const Icon(Icons.audiotrack),
                            ),
                            title: Text(
                              entry.fileName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              entry.relativePath,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: entry.extension.isEmpty
                                ? null
                                : Chip(
                                    label: Text(entry.extension.toUpperCase()),
                                  ),
                          ),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
