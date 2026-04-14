import 'dart:io';

import 'package:audio_core/audio_core.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

class MetadataTab extends StatefulWidget {
  const MetadataTab({super.key, required this.controller});

  final AudioCoreController controller;

  @override
  State<MetadataTab> createState() => _MetadataTabState();
}

class _MetadataTabState extends State<MetadataTab> {
  Future<TrackMetadata>? _metadataFuture;
  String? _trackKey;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleControllerChanged);
    _reloadForCurrentTrack();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerChanged);
    super.dispose();
  }

  void _handleControllerChanged() {
    final nextKey = _currentTrackKey();
    if (nextKey != _trackKey) {
      _reloadForCurrentTrack();
    }
  }

  String? _currentTrackKey() {
    final track = widget.controller.playlist.currentTrack;
    if (track == null) return null;
    return '${track.id}|${widget.controller.player.currentPath ?? track.uri}';
  }

  void _reloadForCurrentTrack() {
    _trackKey = _currentTrackKey();
    _metadataFuture = _loadMetadata();
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _refresh() async {
    final track = widget.controller.playlist.currentTrack;
    if (track == null) return;
    _trackKey = _currentTrackKey();
    setState(() {
      _metadataFuture = _loadMetadata();
    });
    await _metadataFuture;
  }

  Future<TrackMetadata> _loadMetadata() async {
    try {
      return await widget.controller.getTrackMetadata();
    } catch (e) {
      return TrackMetadata(
        error: e.toString(),
        genres: const <String>[],
        pictures: const [],
      );
    }
  }

  Future<void> _changeCover() async {
    final track = widget.controller.playlist.currentTrack;
    if (track == null) return;

    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
    );

    if (result == null || result.files.isEmpty) {
      return;
    }

    final path = result.files.single.path;
    if (path == null || path.isEmpty) return;

    final bytes = await File(path).readAsBytes();
    final ext = result.files.single.extension?.toLowerCase();
    final mimeType = ext == 'png' ? 'image/png' : 'image/jpeg';

    final metadata = await _metadataFuture ??
        const TrackMetadata(genres: <String>[], pictures: <TrackPicture>[]);
    final success = await widget.controller.updateMetadata(
      track,
      metadata: AndroidTrackMetadataUpdate(
        title: metadata.title ?? track.title,
        artist: metadata.artist ?? track.artist,
        album: metadata.album ?? track.album,
        pictures: [AndroidTrackPicture(bytes: bytes, mimeType: mimeType)],
      ),
    );

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          success ? 'Cover updated successfully.' : 'Failed to update cover.',
        ),
        backgroundColor: success ? Colors.green : Colors.red,
      ),
    );

    if (success) {
      await _refresh();
    }
  }

  String _prettyValue(Object? value) {
    if (value == null) return 'Unknown';
    if (value is String && value.trim().isEmpty) return 'Unknown';
    if (value is Iterable) {
      return value.map((item) => item.toString()).join(', ');
    }
    return value.toString();
  }

  Widget _buildFieldRow(String label, Object? value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(label, style: Theme.of(context).textTheme.labelMedium),
          ),
          Expanded(
            child: Text(
              _prettyValue(value),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSection(String title, List<Widget> children) {
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final track = widget.controller.playlist.currentTrack;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ElevatedButton.icon(
                onPressed: track == null ? null : _changeCover,
                icon: const Icon(Icons.edit_note),
                label: const Text('Change Cover'),
              ),
              OutlinedButton.icon(
                onPressed: track == null ? null : _refresh,
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: track == null
                ? Center(
                    child: Text(
                      'No track selected',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  )
                : FutureBuilder<TrackMetadata>(
                    future: _metadataFuture,
                    builder: (context, snapshot) {
                      final metadata = snapshot.data ??
                          const TrackMetadata(
                            genres: <String>[],
                            pictures: <TrackPicture>[],
                          );
                      final pictureList = metadata.pictures;
                      final genres = metadata.genres;
                      final errorText = metadata.error;

                      return ListView(
                        children: [
                          _buildSection('Track', [
                            _buildFieldRow(
                              'Title',
                              metadata.title ?? track.title,
                            ),
                            _buildFieldRow(
                              'Artist',
                              metadata.artist ?? track.artist,
                            ),
                            _buildFieldRow(
                              'Album',
                              metadata.album ?? track.album,
                            ),
                            _buildFieldRow(
                              'Album Artist',
                              metadata.albumArtist,
                            ),
                            _buildFieldRow(
                              'Track No.',
                              metadata.trackNumber,
                            ),
                            _buildFieldRow(
                              'Track Total',
                              metadata.trackTotal,
                            ),
                            _buildFieldRow('Disc No.', metadata.discNumber),
                            _buildFieldRow('Date', metadata.date),
                            _buildFieldRow('Year', metadata.year),
                          ]),
                          _buildSection('Extra', [
                            _buildFieldRow('Comment', metadata.comment),
                            _buildFieldRow('Lyrics', metadata.lyrics),
                            _buildFieldRow('Composer', metadata.composer),
                            _buildFieldRow('Lyricist', metadata.lyricist),
                            _buildFieldRow('Performer', metadata.performer),
                            _buildFieldRow('Conductor', metadata.conductor),
                            _buildFieldRow('Remixer', metadata.remixer),
                            _buildFieldRow(
                              'Genres',
                              genres.isEmpty ? null : genres.join(', '),
                            ),
                          ]),
                          _buildSection('Source', [
                            _buildFieldRow(
                              'Path',
                              widget.controller.player.currentPath ?? track.uri,
                            ),
                            _buildFieldRow('Track Id', track.id),
                            _buildFieldRow('Metadata Type', metadata.metadataType),
                          ]),
                          if (pictureList.isNotEmpty)
                            _buildSection(
                              'Pictures (${pictureList.length})',
                              pictureList.map((picture) {
                                final bytes = picture.bytes;
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 16),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      if (bytes.isNotEmpty)
                                        ClipRRect(
                                          borderRadius:
                                              BorderRadius.circular(12),
                                          child: Image.memory(
                                            bytes,
                                            height: 180,
                                            fit: BoxFit.cover,
                                            width: double.infinity,
                                            filterQuality: FilterQuality.low,
                                            cacheWidth: 960,
                                          ),
                                        ),
                                      const SizedBox(height: 8),
                                      _buildFieldRow('Type', picture.pictureType),
                                      _buildFieldRow('Mime', picture.mimeType),
                                      _buildFieldRow(
                                        'Description',
                                        picture.description,
                                      ),
                                    ],
                                  ),
                                );
                              }).toList(growable: false),
                            ),
                          if (errorText != null && errorText.isNotEmpty)
                            _buildSection('Read Error', [
                              Text(
                                errorText,
                                style: const TextStyle(color: Colors.red),
                              ),
                            ]),
                        ],
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
