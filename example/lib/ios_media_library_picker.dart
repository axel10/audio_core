import 'package:audio_core/audio_core.dart';
import 'package:flutter/material.dart';

Future<IosMediaLibraryEntry?> showIosMediaLibraryPicker(
  BuildContext context, {
  required List<IosMediaLibraryEntry> entries,
}) {
  return showModalBottomSheet<IosMediaLibraryEntry>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => _IosMediaLibraryPickerSheet(entries: entries),
  );
}

class _IosMediaLibraryPickerSheet extends StatefulWidget {
  const _IosMediaLibraryPickerSheet({required this.entries});

  final List<IosMediaLibraryEntry> entries;

  @override
  State<_IosMediaLibraryPickerSheet> createState() =>
      _IosMediaLibraryPickerSheetState();
}

class _IosMediaLibraryPickerSheetState
    extends State<_IosMediaLibraryPickerSheet> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<IosMediaLibraryEntry> get _filteredEntries {
    final normalized = _query.trim().toLowerCase();
    if (normalized.isEmpty) return widget.entries;
    return widget.entries.where((entry) {
      return entry.label.toLowerCase().contains(normalized) ||
          (entry.artist?.toLowerCase().contains(normalized) ?? false) ||
          (entry.album?.toLowerCase().contains(normalized) ?? false);
    }).toList();
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredEntries;
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.82,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'iOS Media Library',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${filtered.length} / ${widget.entries.length} tracks',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search title, artist, or album',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _query = '');
                        },
                        icon: const Icon(Icons.clear),
                      ),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: filtered.isEmpty
                ? const Center(
                    child: Text(
                      'No local non-DRM tracks found in iOS Media Library.',
                    ),
                  )
                : ListView.separated(
                    itemCount: filtered.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final entry = filtered[index];
                      final subtitleParts = <String>[
                        if (entry.artist != null) entry.artist!,
                        if (entry.album != null) entry.album!,
                      ];
                      return ListTile(
                        leading: const Icon(Icons.music_note),
                        title: Text(
                          entry.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: subtitleParts.isEmpty
                            ? null
                            : Text(
                                subtitleParts.join(' • '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                        trailing: entry.durationMs == null
                            ? null
                            : Text(
                                _formatDuration(entry.duration),
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                        onTap: () => Navigator.of(context).pop(entry),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
