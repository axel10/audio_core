import 'dart:io';

import 'package:audio_core/audio_core.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

const List<String> _audioFileExtensions = <String>[
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

class MetadataTab extends StatefulWidget {
  const MetadataTab({super.key, required this.controller});

  final AudioCoreController controller;

  @override
  State<MetadataTab> createState() => _MetadataTabState();
}

class _MetadataTabState extends State<MetadataTab> {
  Future<TrackMetadata>? _metadataFuture;
  String? _trackKey;
  final List<AudioTrack> _sourceTracks = <AudioTrack>[];
  final List<AudioTrack> _targetTracks = <AudioTrack>[];
  bool _isBatchCopying = false;

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

    try {
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

      final metadata =
          await _metadataFuture ??
          const TrackMetadata(genres: <String>[], pictures: <TrackPicture>[]);
      final success = await widget.controller.updateMetadata(
        track,
        metadata: TrackMetadataUpdate(
          title: metadata.title ?? track.title,
          artist: metadata.artist ?? track.artist,
          album: metadata.album ?? track.album,
          pictures: [TrackMetadataPicture(bytes: bytes, mimeType: mimeType)],
        ),
      );

      if (!mounted) return;

      if (success) {
        _showSnackBar(
          'Cover updated successfully.',
          backgroundColor: Colors.green,
        );
        await _refresh();
      } else {
        final message = _metadataFailureMessage('Failed to update cover');
        _logMetadataFailure(message, track: track, extra: 'coverPath=$path');
        _showSnackBar(message, backgroundColor: Colors.red);
      }
    } catch (e, stackTrace) {
      final message = 'Failed to update cover: $e';
      debugPrint('[MetadataTab] $message');
      debugPrintStack(
        label: '[MetadataTab] cover update stack',
        stackTrace: stackTrace,
      );

      if (!mounted) return;
      _showSnackBar(message, backgroundColor: Colors.red);
    }
  }

  String _metadataFailureMessage(String fallback) {
    final error = widget.controller.player.error?.trim();
    if (error == null || error.isEmpty) {
      return '$fallback.';
    }
    return '$fallback: $error';
  }

  void _logMetadataFailure(
    String message, {
    AudioTrack? track,
    AudioTrack? source,
    AudioTrack? target,
    String? extra,
  }) {
    final parts = <String>[
      '[MetadataTab] $message',
      if (track != null) 'track=${_describeTrackForLog(track)}',
      if (source != null) 'source=${_describeTrackForLog(source)}',
      if (target != null) 'target=${_describeTrackForLog(target)}',
      if (extra != null && extra.trim().isNotEmpty) extra,
    ];
    debugPrint(parts.join(' | '));
  }

  String _describeTrackForLog(AudioTrack track) {
    return 'id=${track.id}, uri=${track.uri}';
  }

  void _showSnackBar(String message, {Color? backgroundColor}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: backgroundColor),
    );
  }

  Future<List<AudioTrack>?> _pickAudioTracks(String title) async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: title,
      type: FileType.custom,
      allowedExtensions: _audioFileExtensions,
      allowMultiple: true,
    );

    if (result == null || result.files.isEmpty) {
      return null;
    }

    final mediaUriByPath = <String, String>{};
    final paths = result.files
        .map((file) {
          final path = file.path?.trim();
          if (path == null || path.isEmpty) return null;

          final mediaUri = _pickedFileMediaUri(file);
          if (mediaUri != null && mediaUri.isNotEmpty) {
            mediaUriByPath[_normalizePathKey(path)] = mediaUri;
          }
          return path;
        })
        .whereType<String>()
        .toList(growable: false);

    if (paths.isEmpty) {
      return const <AudioTrack>[];
    }

    final tracks = widget.controller.resolveAudioTracks(paths);
    if (!Platform.isAndroid || tracks.isEmpty || mediaUriByPath.isEmpty) {
      return tracks;
    }

    return tracks
        .map((track) {
          final mediaUri = mediaUriByPath[_normalizePathKey(track.uri)];
          if (mediaUri == null || mediaUri.trim().isEmpty) {
            return track;
          }
          return track.copyWith(
            metadata: <String, Object?>{
              ...track.metadata,
              'mediaUri': mediaUri.trim(),
            },
          );
        })
        .toList(growable: false);
  }

  String? _pickedFileMediaUri(PlatformFile file) {
    final identifier = file.identifier?.trim();
    if (identifier != null && identifier.isNotEmpty) {
      return identifier;
    }

    final path = file.path?.trim();
    if (path != null && path.isNotEmpty) {
      return path;
    }

    return null;
  }

  String _normalizePathKey(String path) {
    return path.trim().replaceAll('\\', '/').toLowerCase();
  }

  void _appendTracks(List<AudioTrack> target, List<AudioTrack> tracks) {
    final existingKeys = target.map(_trackBatchKey).toSet();
    for (final track in tracks) {
      final key = _trackBatchKey(track);
      if (existingKeys.add(key)) {
        target.add(track);
      }
    }
  }

  String _trackBatchKey(AudioTrack track) {
    final mediaUri = track.metadataValue<String>('mediaUri');
    if (mediaUri != null && mediaUri.trim().isNotEmpty) {
      return mediaUri.trim();
    }

    final uri = track.uri.trim();
    if (uri.isNotEmpty) {
      return uri;
    }

    return track.id.trim();
  }

  Future<void> _addSourceTracks() async {
    final tracks = await _pickAudioTracks('Select source audio files');
    if (!mounted || tracks == null) return;
    if (tracks.isEmpty) {
      _showSnackBar(
        'No valid source files were selected.',
        backgroundColor: Colors.red,
      );
      return;
    }

    setState(() {
      _appendTracks(_sourceTracks, tracks);
    });
  }

  Future<void> _addTargetTracks() async {
    final tracks = await _pickAudioTracks('Select target audio files');
    if (!mounted || tracks == null) return;
    if (tracks.isEmpty) {
      _showSnackBar(
        'No valid target files were selected.',
        backgroundColor: Colors.red,
      );
      return;
    }

    setState(() {
      _appendTracks(_targetTracks, tracks);
    });
  }

  void _removeSourceTrack(int index) {
    if (_isBatchCopying) return;
    setState(() {
      _sourceTracks.removeAt(index);
    });
  }

  void _removeTargetTrack(int index) {
    if (_isBatchCopying) return;
    setState(() {
      _targetTracks.removeAt(index);
    });
  }

  String _fileNameFromPath(String path) {
    final normalized = path.replaceAll('\\', '/');
    final parts = normalized.split('/');
    return parts.isEmpty ? path : parts.last;
  }

  String _describeTrack(AudioTrack track) {
    final title = track.title?.trim();
    final fallbackName = _fileNameFromPath(track.uri);
    final displayTitle = (title == null || title.isEmpty)
        ? fallbackName
        : title;
    final mediaUri = track.metadataValue<String>('mediaUri')?.trim();
    final filePath = track.metadataValue<String>('filePath')?.trim();
    final selectedUri = track.metadataValue<String>('selectedUri')?.trim();
    final lookup = track.metadataValue<String>('mediaUriLookup')?.trim();
    return [
      displayTitle,
      'uri: ${track.uri}',
      'mediaUri: ${mediaUri == null || mediaUri.isEmpty ? '(none)' : mediaUri}',
      if (filePath != null && filePath.isNotEmpty) 'filePath: $filePath',
      if (selectedUri != null && selectedUri.isNotEmpty)
        'selectedUri: $selectedUri',
      if (lookup != null && lookup.isNotEmpty) 'lookup: $lookup',
    ].join('\n');
  }

  bool get _canCopyBatch =>
      !_isBatchCopying &&
      _sourceTracks.isNotEmpty &&
      _sourceTracks.length == _targetTracks.length;

  Future<void> _copyMetadataBatch() async {
    if (!_canCopyBatch) {
      _showSnackBar(
        'Source and target counts must match before copying.',
        backgroundColor: Colors.red,
      );
      return;
    }

    final sourceTracks = List<AudioTrack>.from(_sourceTracks);
    final targetTracks = List<AudioTrack>.from(_targetTracks);

    if (sourceTracks.length != targetTracks.length) {
      _showSnackBar(
        'Source and target counts must match. '
        'Selected ${sourceTracks.length} source file(s) and '
        '${targetTracks.length} target file(s).',
        backgroundColor: Colors.red,
      );
      return;
    }

    setState(() {
      _isBatchCopying = true;
    });

    try {
      final results = await widget.controller.copyMetadataPairs(
        sourceTracks,
        targetTracks,
      );
      final successCount = results.where((success) => success).length;
      String? lastFailureMessage;

      for (var i = 0; i < results.length; i++) {
        if (!results[i]) {
          lastFailureMessage = _metadataFailureMessage(
            'Metadata copy failed for pair ${i + 1}',
          );
          _logMetadataFailure(
            lastFailureMessage,
            source: sourceTracks[i],
            target: targetTracks[i],
          );
        }
      }

      if (!mounted) return;

      if (successCount == sourceTracks.length) {
        _showSnackBar(
          'Copied metadata for $successCount file pair(s).',
          backgroundColor: Colors.green,
        );
      } else {
        final details = lastFailureMessage == null
            ? ''
            : '\nLast error: $lastFailureMessage';
        _showSnackBar(
          'Copied metadata for $successCount of ${sourceTracks.length} file pair(s).$details',
          backgroundColor: Colors.orange,
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isBatchCopying = false;
        });
      }
    }
  }

  Widget _buildBatchTrackSection({
    required String title,
    required String emptyLabel,
    required List<AudioTrack> tracks,
    required VoidCallback onAdd,
    required void Function(int index) onRemove,
  }) {
    final countLabel = tracks.isEmpty
        ? '0 selected'
        : '${tracks.length} selected';
    final canEdit = !_isBatchCopying;

    return _buildSection(title, [
      Row(
        children: [
          ElevatedButton.icon(
            onPressed: canEdit ? onAdd : null,
            icon: const Icon(Icons.add),
            label: const Text('Add Files'),
          ),
          const SizedBox(width: 12),
          Text(countLabel, style: Theme.of(context).textTheme.labelMedium),
        ],
      ),
      const SizedBox(height: 12),
      if (tracks.isEmpty)
        Text(emptyLabel, style: Theme.of(context).textTheme.bodyMedium)
      else
        ListView.separated(
          itemCount: tracks.length,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final track = tracks[index];
            return Container(
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.surface.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Theme.of(
                    context,
                  ).colorScheme.outlineVariant.withValues(alpha: 0.7),
                ),
              ),
              child: ListTile(
                dense: true,
                title: Text(
                  track.title ?? _fileNameFromPath(track.uri),
                  softWrap: true,
                ),
                subtitle: Text(_describeTrack(track), softWrap: true),
                trailing: IconButton(
                  onPressed: canEdit ? () => onRemove(index) : null,
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Remove',
                ),
              ),
            );
          },
        ),
    ]);
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
            child: ListView(
              children: [
                _buildSection('Batch Copy Metadata', [
                  Text(
                    'Add source files and target files in matching order. '
                    'Each source file copies its metadata to the target file at the same position.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 12),
                  _buildBatchTrackSection(
                    title: 'Source Files',
                    emptyLabel:
                        'No source files selected yet. Tap Add Files to choose one or more source tracks.',
                    tracks: _sourceTracks,
                    onAdd: _addSourceTracks,
                    onRemove: _removeSourceTrack,
                  ),
                  const SizedBox(height: 12),
                  _buildBatchTrackSection(
                    title: 'Target Files',
                    emptyLabel:
                        'No target files selected yet. Tap Add Files to choose one or more target tracks.',
                    tracks: _targetTracks,
                    onAdd: _addTargetTracks,
                    onRemove: _removeTargetTrack,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _isBatchCopying
                              ? 'Copying metadata...'
                              : _sourceTracks.isNotEmpty &&
                                    _sourceTracks.length == _targetTracks.length
                              ? 'Ready to copy ${_sourceTracks.length} pair(s).'
                              : 'Source and target counts must match.',
                          style: TextStyle(
                            color:
                                _sourceTracks.isNotEmpty &&
                                    _sourceTracks.length == _targetTracks.length
                                ? Colors.green
                                : Colors.red,
                          ),
                        ),
                      ),
                      ElevatedButton.icon(
                        onPressed: _canCopyBatch ? _copyMetadataBatch : null,
                        icon: _isBatchCopying
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.copy_all),
                        label: Text(
                          _isBatchCopying ? 'Copying...' : 'Copy Metadata',
                        ),
                      ),
                    ],
                  ),
                ]),
                const SizedBox(height: 16),
                if (track == null)
                  SizedBox(
                    height: 160,
                    child: Center(
                      child: Text(
                        'No track selected',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  )
                else
                  FutureBuilder<TrackMetadata>(
                    future: _metadataFuture,
                    builder: (context, snapshot) {
                      final metadata =
                          snapshot.data ??
                          const TrackMetadata(
                            genres: <String>[],
                            pictures: <TrackPicture>[],
                          );
                      final pictureList = metadata.pictures;
                      final genres = metadata.genres;
                      final errorText = metadata.error;

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
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
                            _buildFieldRow('Track No.', metadata.trackNumber),
                            _buildFieldRow('Track Total', metadata.trackTotal),
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
                            _buildFieldRow(
                              'Metadata Type',
                              metadata.metadataType,
                            ),
                          ]),
                          if (pictureList.isNotEmpty)
                            _buildSection(
                              'Pictures (${pictureList.length})',
                              pictureList
                                  .map((picture) {
                                    final bytes = picture.bytes;
                                    return Padding(
                                      padding: const EdgeInsets.only(
                                        bottom: 16,
                                      ),
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
                                                filterQuality:
                                                    FilterQuality.low,
                                                cacheWidth: 960,
                                              ),
                                            ),
                                          const SizedBox(height: 8),
                                          _buildFieldRow(
                                            'Type',
                                            picture.pictureType,
                                          ),
                                          _buildFieldRow(
                                            'Mime',
                                            picture.mimeType,
                                          ),
                                          _buildFieldRow(
                                            'Description',
                                            picture.description,
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
              ],
            ),
          ),
        ],
      ),
    );
  }
}
