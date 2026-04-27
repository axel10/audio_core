import 'dart:io';

import 'package:audio_core/audio_core.dart';
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

class AppleMusicDirectoryNode {
  AppleMusicDirectoryNode({
    required this.name,
    required this.path,
    this.isRoot = false,
  });

  final String name;
  final String path;
  final bool isRoot;

  final Map<String, AppleMusicDirectoryNode> _childrenByName =
      <String, AppleMusicDirectoryNode>{};
  final List<AppleMusicFileEntry> _files = <AppleMusicFileEntry>[];

  String get displayName => name;

  List<AppleMusicDirectoryNode> get children {
    final children = _childrenByName.values.toList(growable: false);
    children.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    return children;
  }

  List<AppleMusicFileEntry> get files {
    final files = _files.toList(growable: false);
    files.sort(
      (a, b) => a.fileName.toLowerCase().compareTo(b.fileName.toLowerCase()),
    );
    return files;
  }

  int get trackCount =>
      _files.length +
      _childrenByName.values.fold<int>(
        0,
        (sum, child) => sum + child.trackCount,
      );

  AppleMusicDirectoryNode childForName(String childName, String childPath) {
    return _childrenByName.putIfAbsent(
      childName,
      () => AppleMusicDirectoryNode(name: childName, path: childPath),
    );
  }

  void addFile(AppleMusicFileEntry entry) {
    _files.add(entry);
  }
}

class AppleDirectoryTab extends StatefulWidget {
  const AppleDirectoryTab({super.key, required this.controller});

  final AudioCoreController controller;

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
  AppleMusicDirectoryNode? _directoryTree;
  String? _currentPlayingPath;

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
      _directoryTree = null;
      _lastScannedAt = null;
    });

    try {
      final tree = await _scanMusicFiles(selected);
      if (!mounted) return;
      setState(() {
        _directoryTree = tree;
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

  Future<AppleMusicDirectoryNode> _scanMusicFiles(String directoryPath) async {
    final root = Directory(directoryPath);
    if (!await root.exists()) {
      throw StateError('Directory does not exist: $directoryPath');
    }

    final normalizedRoot = _normalizeDirectoryPath(directoryPath);
    final entries = <AppleMusicFileEntry>[];

    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final extension = _extensionForPath(entity.path);
      if (!_audioFileExtensions.contains(extension)) continue;
      entries.add(
        AppleMusicFileEntry(
          path: entity.path,
          relativePath: _relativePath(normalizedRoot, entity.path),
        ),
      );
    }

    return _buildDirectoryTree(directoryPath, entries);
  }

  AppleMusicDirectoryNode _buildDirectoryTree(
    String rootPath,
    List<AppleMusicFileEntry> entries,
  ) {
    final rootName = _folderName(rootPath);
    final root = AppleMusicDirectoryNode(
      name: rootName.isEmpty ? 'Selected Folder' : rootName,
      path: rootPath,
      isRoot: true,
    );

    for (final entry in entries) {
      final segments = entry.relativePath
          .split('/')
          .where((segment) => segment.isNotEmpty)
          .toList(growable: false);
      if (segments.isEmpty) {
        root.addFile(entry);
        continue;
      }

      var current = root;
      var currentPath = '';
      for (var i = 0; i < segments.length - 1; i++) {
        final segment = segments[i];
        currentPath = currentPath.isEmpty ? segment : '$currentPath/$segment';
        current = current.childForName(segment, currentPath);
      }
      current.addFile(entry);
    }

    return root;
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

  String _folderName(String path) {
    final normalized = _normalizeDirectoryPath(path);
    if (normalized.isEmpty) return '';
    final parts = normalized.split('/').where((segment) => segment.isNotEmpty);
    return parts.isEmpty ? normalized : parts.last;
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

  Future<void> _playEntry(AppleMusicFileEntry entry) async {
    try {
      await widget.controller.playPaths([entry.path], autoPlayFirst: true);
      if (!mounted) return;
      setState(() {
        _currentPlayingPath = entry.path;
        _errorMessage = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Playback failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tree = _directoryTree;
    final hasTracks = tree != null && tree.trackCount > 0;

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
                      'Pick a folder and browse music in a tree view.',
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
              'Found ${tree?.trackCount ?? 0} music files. Last scanned at ${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(_lastScannedAt!))}.',
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
                  : tree == null
                  ? Center(
                      child: Text(
                        _selectedDirectory == null
                            ? 'Choose a folder to start scanning.'
                            : 'No music files found in this folder.',
                      ),
                    )
                  : hasTracks
                  ? ListView(
                      padding: const EdgeInsets.all(12),
                      children: [
                        _buildFolderNode(context, tree, theme: theme, depth: 0),
                      ],
                    )
                  : Center(
                      child: Text(
                        'No music files found in this folder.',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFolderNode(
    BuildContext context,
    AppleMusicDirectoryNode node, {
    required ThemeData theme,
    required int depth,
  }) {
    final indent = 12.0 * depth;
    final folderChildren = node.children;
    final files = node.files;

    if (node.isRoot) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Card(
            elevation: 0,
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: theme.colorScheme.primaryContainer,
                child: const Icon(Icons.folder_copy),
              ),
              title: Text(
                node.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text('${node.trackCount} tracks'),
            ),
          ),
          const SizedBox(height: 8),
          if (files.isNotEmpty)
            ...files.map(
              (file) => _buildTrackTile(
                context,
                file,
                theme: theme,
                depth: depth + 1,
              ),
            ),
          if (folderChildren.isNotEmpty)
            ...folderChildren.map(
              (child) => _buildFolderNode(
                context,
                child,
                theme: theme,
                depth: depth + 1,
              ),
            ),
        ],
      );
    }

    return Padding(
      padding: EdgeInsets.only(left: indent),
      child: Card(
        elevation: 0,
        child: ExpansionTile(
          key: PageStorageKey<String>('folder:${node.path}'),
          leading: const Icon(Icons.folder),
          title: Text(
            node.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text('${node.trackCount} tracks'),
          childrenPadding: const EdgeInsets.only(bottom: 8),
          children: [
            if (files.isNotEmpty)
              ...files.map(
                (file) => _buildTrackTile(
                  context,
                  file,
                  theme: theme,
                  depth: depth + 1,
                ),
              ),
            if (folderChildren.isNotEmpty)
              ...folderChildren.map(
                (child) => _buildFolderNode(
                  context,
                  child,
                  theme: theme,
                  depth: depth + 1,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildTrackTile(
    BuildContext context,
    AppleMusicFileEntry entry, {
    required ThemeData theme,
    required int depth,
  }) {
    final isPlaying = _currentPlayingPath == entry.path;
    return Padding(
      padding: EdgeInsets.only(left: 12.0 * depth, bottom: 8),
      child: Card(
        elevation: 0,
        child: ListTile(
          leading: CircleAvatar(
            backgroundColor: isPlaying
                ? theme.colorScheme.primary
                : theme.colorScheme.primaryContainer,
            foregroundColor: isPlaying
                ? theme.colorScheme.onPrimary
                : theme.colorScheme.onPrimaryContainer,
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
              ? const Icon(Icons.play_arrow)
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Chip(label: Text(entry.extension.toUpperCase())),
                    const SizedBox(width: 8),
                    const Icon(Icons.play_arrow),
                  ],
                ),
          onTap: () => _playEntry(entry),
        ),
      ),
    );
  }
}
