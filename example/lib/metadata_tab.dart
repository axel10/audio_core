import 'dart:io';
import 'dart:typed_data';

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
  Future<Map<String, Object?>>? _metadataFuture;
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
    final track = widget.controller.playlist.currentTrack;
    _trackKey = _currentTrackKey();
    _metadataFuture = _loadMetadata(track);
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _refresh() async {
    final track = widget.controller.playlist.currentTrack;
    if (track == null) return;
    _trackKey = _currentTrackKey();
    setState(() {
      _metadataFuture = _loadMetadata(track);
    });
    await _metadataFuture;
  }

  Future<Map<String, Object?>> _loadMetadata(AudioTrack? track) async {
    if (track == null) {
      return <String, Object?>{};
    }

    try {
      return await widget.controller.getTrackMetadata(track);
    } catch (e) {
      return <String, Object?>{'_error': e.toString()};
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

    final metadata = await _metadataFuture ?? <String, Object?>{};
    final success = await widget.controller.updateMetadata(
      track,
      metadata: AndroidTrackMetadataUpdate(
        title: _asString(metadata, ['title']) ?? track.title,
        artist: _asString(metadata, ['artist']) ?? track.artist,
        album: _asString(metadata, ['album']) ?? track.album,
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

  String? _asString(Map<String, Object?> metadata, List<String> keys) {
    for (final key in keys) {
      final value = metadata[key];
      if (value == null) continue;
      final text = value.toString().trim();
      if (text.isNotEmpty) return text;
    }
    return null;
  }

  List<String> _asStringList(Object? value) {
    if (value is List) {
      return value.map((item) => item.toString()).toList(growable: false);
    }
    return const <String>[];
  }

  Uint8List? _pictureBytes(Object? value) {
    if (value is Uint8List) return value;
    if (value is List<int>) return Uint8List.fromList(value);
    return null;
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
                : FutureBuilder<Map<String, Object?>>(
                    future: _metadataFuture,
                    builder: (context, snapshot) {
                      final metadata =
                          snapshot.data ?? const <String, Object?>{};
                      final pictures = metadata['pictures'];
                      final pictureList = pictures is List
                          ? pictures.cast<Object?>()
                          : const <Object?>[];
                      final genres = _asStringList(metadata['genres']);
                      final errorText = metadata['_error']?.toString();

                      return ListView(
                        children: [
                          _buildSection('Track', [
                            _buildFieldRow(
                              'Title',
                              metadata['title'] ?? track.title,
                            ),
                            _buildFieldRow(
                              'Artist',
                              metadata['artist'] ?? track.artist,
                            ),
                            _buildFieldRow(
                              'Album',
                              metadata['album'] ?? track.album,
                            ),
                            _buildFieldRow(
                              'Album Artist',
                              metadata['albumArtist'],
                            ),
                            _buildFieldRow(
                              'Track No.',
                              metadata['trackNumber'],
                            ),
                            _buildFieldRow(
                              'Track Total',
                              metadata['trackTotal'],
                            ),
                            _buildFieldRow('Disc No.', metadata['discNumber']),
                            _buildFieldRow('Date', metadata['date']),
                            _buildFieldRow('Year', metadata['year']),
                          ]),
                          _buildSection('Extra', [
                            _buildFieldRow('Comment', metadata['comment']),
                            _buildFieldRow('Lyrics', metadata['lyrics']),
                            _buildFieldRow('Composer', metadata['composer']),
                            _buildFieldRow('Lyricist', metadata['lyricist']),
                            _buildFieldRow('Performer', metadata['performer']),
                            _buildFieldRow('Conductor', metadata['conductor']),
                            _buildFieldRow('Remixer', metadata['remixer']),
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
                            _buildFieldRow(
                              'Metadata Type',
                              metadata['metadataType'],
                            ),
                          ]),
                          if (pictureList.isNotEmpty)
                            _buildSection(
                              'Pictures (${pictureList.length})',
                              pictureList
                                  .map((picture) {
                                    final pictureMap = picture is Map
                                        ? picture.cast<String, Object?>()
                                        : const <String, Object?>{};
                                    final bytes = _pictureBytes(
                                      pictureMap['bytes'],
                                    );
                                    final mimeType = pictureMap['mimeType'];
                                    final pictureType =
                                        pictureMap['pictureType'];
                                    final description =
                                        pictureMap['description'];

                                    return Padding(
                                      padding: const EdgeInsets.only(
                                        bottom: 16,
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          if (bytes != null && bytes.isNotEmpty)
                                            ClipRRect(
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                              child: Image.memory(
                                                bytes,
                                                height: 180,
                                                fit: BoxFit.cover,
                                                width: double.infinity,
                                                filterQuality:
                                                    FilterQuality.low,
                                                cacheWidth: 960,
                                              ),
                                            ),
                                          const SizedBox(height: 8),
                                          _buildFieldRow('Type', pictureType),
                                          _buildFieldRow('Mime', mimeType),
                                          _buildFieldRow(
                                            'Description',
                                            description,
                                          ),
                                        ],
                                      ),
                                    );
                                  })
                                  .toList(growable: false),
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
