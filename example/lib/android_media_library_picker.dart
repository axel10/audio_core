import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audio_core/audio_core.dart';

class AndroidMediaLibraryApi {
  static const MethodChannel _channel = MethodChannel(
    'audio_core.media_library',
  );

  Future<bool> ensureAudioPermission() async {
    final granted = await _channel.invokeMethod<bool>('ensureAudioPermission');
    return granted ?? false;
  }

  Future<List<AudioLibraryEntry>> scanAudioLibrary() async {
    final result = await _channel.invokeMethod<List<dynamic>>(
      'scanAudioLibrary',
    );
    if (result == null) return const [];
    return result
        .whereType<Map>()
        .map((item) => AudioLibraryEntry.fromMap(item.cast<dynamic, dynamic>()))
        .toList();
  }
}

class AudioLibraryEntry {
  const AudioLibraryEntry({
    required this.id,
    required this.uri,
    required this.title,
    required this.folderPath,
    this.displayName,
    this.artist,
    this.album,
    this.durationMs,
    this.bucketDisplayName,
    this.mimeType,
  });

  final String id;
  final String uri;
  final String title;
  final String folderPath;
  final String? displayName;
  final String? artist;
  final String? album;
  final int? durationMs;
  final String? bucketDisplayName;
  final String? mimeType;

  Duration get duration => Duration(
    milliseconds: durationMs == null
        ? 0
        : durationMs!.clamp(0, 1 << 31).toInt(),
  );

  String get label => title.trim().isEmpty
      ? (displayName?.trim().isNotEmpty == true ? displayName!.trim() : uri)
      : title.trim();

  AudioTrack toAudioTrack() {
    return AudioTrack(
      id: id,
      uri: uri,
      title: label,
      artist: artist,
      album: album,
      duration: durationMs == null ? null : Duration(milliseconds: durationMs!),
      metadata: <String, Object?>{
        'isLike': false,
        'playCount': 0,
        'folderPath': folderPath,
        if (displayName != null) 'displayName': displayName,
        if (bucketDisplayName != null) 'bucketDisplayName': bucketDisplayName,
        if (mimeType != null) 'mimeType': mimeType,
      },
    );
  }

  factory AudioLibraryEntry.fromMap(Map<dynamic, dynamic> map) {
    return AudioLibraryEntry(
      id: map['id']?.toString() ?? '',
      uri: map['uri']?.toString() ?? '',
      title:
          map['title']?.toString() ??
          map['displayName']?.toString() ??
          'Unknown title',
      folderPath: _normalizeFolderPath(map['relativePath']?.toString() ?? ''),
      displayName: map['displayName']?.toString(),
      artist: map['artist']?.toString(),
      album: map['album']?.toString(),
      durationMs: (map['durationMs'] as num?)?.toInt(),
      bucketDisplayName: map['bucketDisplayName']?.toString(),
      mimeType: map['mimeType']?.toString(),
    );
  }
}

class AudioLibraryFolder {
  AudioLibraryFolder({required this.name, required this.path});

  final String name;
  final String path;
  final List<AudioLibraryFolder> children = <AudioLibraryFolder>[];
  final List<AudioLibraryEntry> items = <AudioLibraryEntry>[];

  String get displayName => path.isEmpty ? 'All Audio' : name;

  int get trackCount =>
      items.length +
      children.fold<int>(0, (sum, child) => sum + child.trackCount);

  AudioLibraryFolder? childByPath(String childPath) {
    for (final child in children) {
      if (child.path == childPath) return child;
    }
    return null;
  }
}

AudioLibraryFolder buildAudioLibraryTree(List<AudioLibraryEntry> entries) {
  final root = AudioLibraryFolder(name: 'All Audio', path: '');
  final nodes = <String, AudioLibraryFolder>{'': root};

  for (final entry in entries) {
    final normalized = _normalizeFolderPath(entry.folderPath);
    if (normalized.isEmpty) {
      root.items.add(entry);
      continue;
    }

    final segments = normalized
        .split('/')
        .where((segment) => segment.isNotEmpty);
    var currentPath = '';
    AudioLibraryFolder current = root;
    for (final segment in segments) {
      currentPath = currentPath.isEmpty ? segment : '$currentPath/$segment';
      final existing = nodes[currentPath];
      if (existing != null) {
        current = existing;
        continue;
      }

      final next = AudioLibraryFolder(name: segment, path: currentPath);
      nodes[currentPath] = next;
      current.children.add(next);
      current = next;
    }
    current.items.add(entry);
  }

  _sortFolderTree(root);
  return root;
}

void _sortFolderTree(AudioLibraryFolder folder) {
  folder.children.sort(
    (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
  );
  folder.items.sort(
    (a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()),
  );
  for (final child in folder.children) {
    _sortFolderTree(child);
  }
}

String _normalizeFolderPath(String path) {
  final cleaned = path.replaceAll('\\', '/').trim();
  if (cleaned.isEmpty) return '';
  return cleaned.endsWith('/')
      ? cleaned.substring(0, cleaned.length - 1)
      : cleaned;
}

Future<AudioLibraryEntry?> showAndroidMediaLibraryPicker(
  BuildContext context, {
  required AudioLibraryFolder root,
}) {
  return showModalBottomSheet<AudioLibraryEntry>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _AudioLibrarySheet(root: root),
  );
}

class _AudioLibrarySheet extends StatefulWidget {
  const _AudioLibrarySheet({required this.root});

  final AudioLibraryFolder root;

  @override
  State<_AudioLibrarySheet> createState() => _AudioLibrarySheetState();
}

class _AudioLibrarySheetState extends State<_AudioLibrarySheet> {
  final TextEditingController _searchController = TextEditingController();
  final List<AudioLibraryFolder> _breadcrumbs = <AudioLibraryFolder>[];
  late AudioLibraryFolder _currentFolder;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _currentFolder = widget.root;
    _breadcrumbs.add(widget.root);
    _searchController.addListener(() {
      setState(() {
        _query = _searchController.text.trim().toLowerCase();
      });
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _enterFolder(AudioLibraryFolder folder) {
    setState(() {
      _currentFolder = folder;
      _breadcrumbs.add(folder);
    });
  }

  void _goBack() {
    if (_breadcrumbs.length <= 1) return;
    setState(() {
      _breadcrumbs.removeLast();
      _currentFolder = _breadcrumbs.last;
    });
  }

  bool _matchesQuery(AudioLibraryEntry entry) {
    if (_query.isEmpty) return true;
    return [
      entry.label,
      entry.artist ?? '',
      entry.album ?? '',
      entry.folderPath,
      entry.displayName ?? '',
    ].any((value) => value.toLowerCase().contains(_query));
  }

  List<AudioLibraryEntry> _allEntries(AudioLibraryFolder folder) {
    final items = <AudioLibraryEntry>[...folder.items];
    for (final child in folder.children) {
      items.addAll(_allEntries(child));
    }
    return items;
  }

  @override
  Widget build(BuildContext context) {
    final searching = _query.isNotEmpty;
    final folderChildren = searching
        ? const <AudioLibraryFolder>[]
        : _currentFolder.children;
    final filteredItems = searching
        ? _allEntries(widget.root).where(_matchesQuery).toList()
        : _currentFolder.items.where(_matchesQuery).toList();
    final theme = Theme.of(context);

    return FractionallySizedBox(
      heightFactor: 0.93,
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Choose audio',
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${widget.root.trackCount} tracks',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: 'Search title, artist, album, folder',
                  prefixIcon: const Icon(Icons.search),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  if (_breadcrumbs.length > 1)
                    IconButton(
                      onPressed: _goBack,
                      icon: const Icon(Icons.arrow_back),
                      tooltip: 'Back',
                    ),
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: _breadcrumbs
                            .map(
                              (folder) => Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: Chip(
                                  label: Text(folder.displayName),
                                  backgroundColor: folder == _currentFolder
                                      ? theme.colorScheme.primaryContainer
                                      : theme
                                            .colorScheme
                                            .surfaceContainerHighest,
                                ),
                              ),
                            )
                            .toList(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [
                  if (folderChildren.isNotEmpty) ...[
                    Text(
                      'Folders',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    ...folderChildren.map(
                      (folder) => Card(
                        child: ListTile(
                          leading: const Icon(Icons.folder),
                          title: Text(folder.displayName),
                          subtitle: Text('${folder.trackCount} tracks'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _enterFolder(folder),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  Text(
                    searching ? 'Search results' : 'Tracks',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (filteredItems.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 48),
                      child: Center(
                        child: Text(
                          _query.isEmpty
                              ? 'No audio files in this folder'
                              : 'No tracks match your search',
                        ),
                      ),
                    )
                  else
                    ...filteredItems.map(
                      (entry) => Card(
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: theme.colorScheme.primaryContainer,
                            child: const Icon(Icons.music_note),
                          ),
                          title: Text(entry.label),
                          subtitle: Text(
                            [
                              if ((entry.artist ?? '').trim().isNotEmpty)
                                entry.artist!.trim(),
                              if ((entry.album ?? '').trim().isNotEmpty)
                                entry.album!.trim(),
                              if (entry.folderPath.isNotEmpty) entry.folderPath,
                            ].join(' • '),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: const Icon(Icons.play_arrow),
                          onTap: () => Navigator.of(context).pop(entry),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
