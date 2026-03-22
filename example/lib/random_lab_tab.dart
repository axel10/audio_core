import 'dart:async';
import 'package:flutter/material.dart';
import 'package:audio_visualizer_player/audio_visualizer_player.dart';
import 'widgets.dart';

enum RandomPreset {
  off,
  shuffleAll,
  activePlaylist,
  queueOnly,
  likedOnly,
  playCountWeighted,
}

class RandomLabTab extends StatefulWidget {
  final AudioVisualizerPlayerController controller;

  const RandomLabTab({super.key, required this.controller});

  @override
  State<RandomLabTab> createState() => RandomLabTabState();
}

class RandomLabTabState extends State<RandomLabTab> {
  final List<AudioTrack> _libraryTracks = <AudioTrack>[];
  String? _selectedPlaylistId;
  RandomPreset _randomPreset = RandomPreset.off;
  RandomStrategyKind _selectedStrategy = RandomStrategyKind.fisherYates;
  static const String _demoPlaylistId = 'demo_random_lab';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_ensureDemoPlaylist());
      }
    });
  }

  void addTracksToLibrary(List<AudioTrack> tracks) {
    if (tracks.isEmpty) return;
    final libraryIds = _libraryTracks.map((e) => e.id).toSet();
    final newTracks = tracks
        .where((track) => !libraryIds.contains(track.id))
        .toList(growable: false);

    if (newTracks.isNotEmpty) {
      setState(() {
        _libraryTracks.addAll(newTracks);
      });
    }
  }

  Future<void> _ensureDemoPlaylist() async {
    try {
      await widget.controller.playlist.createPlaylist(
        _demoPlaylistId,
        'Random Lab Playlist',
      );
    } catch (_) {
      // Already exists.
    }

    if (!mounted) return;
    setState(() {
      _selectedPlaylistId ??= _demoPlaylistId;
    });
  }

  void _syncTrackInLibrary(AudioTrack updatedTrack) {
    final idx = _libraryTracks.indexWhere(
      (track) => track.id == updatedTrack.id,
    );
    if (idx >= 0) {
      _libraryTracks[idx] = updatedTrack;
    } else {
      _libraryTracks.add(updatedTrack);
    }
  }

  Future<void> _toggleLike(AudioTrack track) async {
    final liked = track.metadataValue<bool>('isLike') ?? false;
    final updated = track.copyWith(
      metadata: <String, Object?>{...track.metadata, 'isLike': !liked},
    );
    setState(() {
      _syncTrackInLibrary(updated);
    });
    await widget.controller.playlist.replaceTrack(updated);
  }

  Future<void> _bumpPlayCount(AudioTrack track) async {
    final playCount = track.metadataValue<int>('playCount') ?? 0;
    final updated = track.copyWith(
      metadata: <String, Object?>{
        ...track.metadata,
        'playCount': playCount + 1,
      },
    );
    setState(() {
      _syncTrackInLibrary(updated);
    });
    await widget.controller.playlist.replaceTrack(updated);
  }

  Future<void> _applyRandomPreset(RandomPreset preset) async {
    setState(() {
      _randomPreset = preset;
    });
    _updateRandomPolicy();
  }

  void _updateRandomPolicy() {
    final preset = _randomPreset;
    if (preset == RandomPreset.off) {
      widget.controller.playlist.clearShuffle();
      return;
    }

    RandomScope scope;
    switch (preset) {
      case RandomPreset.shuffleAll:
        scope = RandomScope.all();
        break;
      case RandomPreset.activePlaylist:
        scope = RandomScope.activePlaylist();
        break;
      case RandomPreset.queueOnly:
        scope =
            RandomScope.playlist(widget.controller.playlist.queuePlaylistId);
        break;
      case RandomPreset.likedOnly:
        scope = RandomScope.filtered(
          id: 'liked-only',
          predicate:
              (track, index, context) =>
                  track.metadataValue<bool>('isLike') == true,
        );
        break;
      case RandomPreset.playCountWeighted:
        scope = RandomScope.activePlaylist();
        break;
      default:
        scope = RandomScope.all();
    }

    RandomStrategy strategy;
    if (preset == RandomPreset.playCountWeighted) {
      // If the preset itself implies a specific complex strategy, we use it.
      strategy = RandomStrategy.custom(
        id: 'inverse-playcount',
        select: (random, candidates, context) {
          var totalWeight = 0.0;
          final weights = <double>[];
          for (final index in candidates) {
            final track = context.trackAt(index);
            final playCount = track?.metadataValue<int>('playCount') ?? 0;
            final weight = 1.0 / (1 + playCount);
            weights.add(weight);
            totalWeight += weight;
          }

          if (totalWeight <= 0.0) {
            return candidates[random.nextInt(candidates.length)];
          }

          final target = random.nextDouble() * totalWeight;
          var cursor = 0.0;
          for (var i = 0; i < candidates.length; i++) {
            cursor += weights[i];
            if (target <= cursor) {
              return candidates[i];
            }
          }
          return candidates.last;
        },
      );
    } else {
      strategy = _getStrategyForKind(_selectedStrategy);
    }

    widget.controller.playlist.setShuffle(
      scope: scope,
      strategy: strategy,
      avoidRecent: 2,
      historySize: 200,
    );
  }

  RandomStrategy _getStrategyForKind(RandomStrategyKind kind) {
    switch (kind) {
      case RandomStrategyKind.random:
        return RandomStrategy.random();
      case RandomStrategyKind.sequential:
        return RandomStrategy.sequential();
      case RandomStrategyKind.fisherYates:
        return RandomStrategy.fisherYates();
      case RandomStrategyKind.weighted:
        return RandomStrategy.weighted(
          id: 'playcount-weighted',
          weightOf:
              (track, index, context) =>
                  1.0 / (1 + (track.metadataValue<int>('playCount') ?? 0)),
        );
      case RandomStrategyKind.custom:
        // Use random for demo custom strategy if not specific.
        return RandomStrategy.random();
    }
  }

  Playlist? get _selectedPlaylist {
    final playlistId = _selectedPlaylistId;
    if (playlistId == null) return null;
    for (final playlist in widget.controller.playlist.playlists) {
      if (playlist.id == playlistId) return playlist;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return AudioDropRegion(
      controller: widget.controller,
      overlayText: 'Drop files here to import into the random lab',
      onTracksAccepted: (tracks) async {
        addTracksToLibrary(tracks);
        await widget.controller.playlist.ensureQueuePlaylist();
        await widget.controller.playlist.addTracksToPlaylist(
          widget.controller.playlist.queuePlaylistId,
          tracks,
        );
      },
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildRandomHeader(),
            const SizedBox(height: 12),
            Expanded(
              child: Row(
                children: [
                  Expanded(child: _buildLibraryPanel()),
                  const SizedBox(width: 12),
                  Expanded(child: _buildQueuePanel()),
                  const SizedBox(width: 12),
                  Expanded(child: _buildSelectedPlaylistPanel()),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRandomHeader() {
    final shuffleStrategy = widget.controller.playlist.randomPolicy?.strategy;
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        DropdownButton<RandomPreset>(
          value: _randomPreset,
          hint: const Text('Preset Scope'),
          items: const [
            DropdownMenuItem(
              value: RandomPreset.off,
              child: Text('Random Off'),
            ),
            DropdownMenuItem(
              value: RandomPreset.shuffleAll,
              child: Text('Shuffle All'),
            ),
            DropdownMenuItem(
              value: RandomPreset.activePlaylist,
              child: Text('Active Playlist'),
            ),
            DropdownMenuItem(
              value: RandomPreset.queueOnly,
              child: Text('Queue Only'),
            ),
            DropdownMenuItem(
              value: RandomPreset.likedOnly,
              child: Text('Liked Only'),
            ),
            DropdownMenuItem(
              value: RandomPreset.playCountWeighted,
              child: Text('PlayCount Weighted'),
            ),
          ],
          onChanged: (preset) {
            if (preset != null) {
              unawaited(_applyRandomPreset(preset));
            }
          },
        ),
        if (_randomPreset != RandomPreset.off)
          DropdownButton<RandomStrategyKind>(
            value: _selectedStrategy,
            hint: const Text('Strategy'),
            items: RandomStrategyKind.values.map((kind) {
              return DropdownMenuItem(
                value: kind,
                child: Text('Strategy: ${kind.name}'),
              );
            }).toList(),
            onChanged: (kind) {
              if (kind != null) {
                setState(() {
                  _selectedStrategy = kind;
                });
                _updateRandomPolicy();
              }
            },
          ),
        IconButton(
          onPressed:
              widget.controller.player.currentPath == null
                  ? null
                  : () => widget.controller.player.togglePlayPause(),
          icon: Icon(
            widget.controller.player.isPlaying
                ? Icons.pause_circle_filled
                : Icons.play_circle_filled,
            size: 40,
            color:
                widget.controller.player.currentPath == null
                    ? Theme.of(context).disabledColor
                    : Theme.of(context).colorScheme.primary,
          ),
        ),
        ElevatedButton.icon(
          onPressed: widget.controller.playlist.randomHistory.isEmpty
              ? null
              : () {
                  widget.controller.playlist.clearShuffleHistory();
                },
          icon: const Icon(Icons.history_toggle_off),
          label: const Text('Clear History'),
        ),
        ElevatedButton.icon(
          onPressed: widget.controller.player.currentPath == null
              ? null
              : () => widget.controller.playlist.playPrevious(),
          icon: const Icon(Icons.skip_previous),
          label: const Text('Prev'),
        ),
        ElevatedButton.icon(
          onPressed: widget.controller.player.currentPath == null
              ? null
              : () => widget.controller.playlist.playNext(),
          icon: const Icon(Icons.skip_next),
          label: const Text('Next'),
        ),
        Text(
          'Shuffle: ${shuffleStrategy?.key ?? 'off'}',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        Text(
          'History: ${widget.controller.playlist.randomHistory.length}',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ],
    );
  }

  Widget _buildLibraryPanel() {
    return _buildTrackPanel(
      title: 'Library',
      subtitle: 'Imported tracks you can drag into the queue or playlists.',
      child: _libraryTracks.isEmpty
          ? _emptyPanel('Import audio files to populate the library.')
          : ListView.separated(
              itemCount: _libraryTracks.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final track = _libraryTracks[index];
                return _TrackDraggableTile(
                  track: track,
                  onToggleLike: () => _toggleLike(track),
                  onBumpPlayCount: () => _bumpPlayCount(track),
                );
              },
            ),
    );
  }

  Widget _buildQueuePanel() {
    final queuePlaylist = widget.controller.playlist.playlistById(
      widget.controller.playlist.queuePlaylistId,
    );
    final tracks = queuePlaylist?.items ?? const <AudioTrack>[];
    return DragTarget<AudioTrack>(
      onAcceptWithDetails: (details) async {
        await widget.controller.playlist.ensureQueuePlaylist();
        await widget.controller.playlist.addTracksToPlaylist(
          widget.controller.playlist.queuePlaylistId,
          <AudioTrack>[details.data],
        );
      },
      builder: (context, candidate, rejected) {
        return _buildTrackPanel(
          title: 'Queue',
          subtitle: 'Drop here to append to the current queue.',
          highlight: candidate.isNotEmpty,
          child: tracks.isEmpty
              ? _emptyPanel('Drop a track here to append it to the queue.')
              : ListView.separated(
                  itemCount: tracks.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final track = tracks[index];
                    return _TrackSummaryTile(
                      track: track,
                      trailing: const Icon(Icons.queue_music),
                    );
                  },
                ),
        );
      },
    );
  }

  Widget _buildSelectedPlaylistPanel() {
    final playlists = widget.controller.playlist.playlists;
    final selectedPlaylist = _selectedPlaylist;
    final selectedId =
        _selectedPlaylistId ??
        (playlists.isNotEmpty ? playlists.first.id : null);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: DropdownButton<String>(
                isExpanded: true,
                value: selectedId,
                hint: const Text('Select playlist'),
                items: playlists
                    .map(
                      (playlist) => DropdownMenuItem(
                        value: playlist.id,
                        child: Text(playlist.name),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  setState(() {
                    _selectedPlaylistId = value;
                  });
                },
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'Create playlist',
              onPressed: () async {
                final id = 'playlist_${DateTime.now().millisecondsSinceEpoch}';
                await widget.controller.playlist.createPlaylist(
                  id,
                  'Playlist ${(playlists.length + 1).toString()}',
                );
                if (!mounted) return;
                setState(() {
                  _selectedPlaylistId = id;
                });
              },
              icon: const Icon(Icons.playlist_add),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: DragTarget<AudioTrack>(
            onAcceptWithDetails: (details) async {
              final playlistId = _selectedPlaylistId;
              if (playlistId == null) return;
              await widget.controller.playlist.addTracksToPlaylist(
                playlistId,
                <AudioTrack>[details.data],
              );
            },
            builder: (context, candidate, rejected) {
              return _buildTrackPanel(
                title: 'Playlist',
                subtitle:
                    selectedPlaylist?.name ??
                    'Pick a playlist and drop tracks here.',
                highlight: candidate.isNotEmpty,
                child:
                    selectedPlaylist == null || selectedPlaylist.items.isEmpty
                    ? _emptyPanel(
                        'Drop tracks here to build the selected playlist.',
                      )
                    : ListView.separated(
                        itemCount: selectedPlaylist.items.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final track = selectedPlaylist.items[index];
                          return _TrackSummaryTile(
                            track: track,
                            trailing: const Icon(Icons.playlist_play),
                          );
                        },
                      ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildTrackPanel({
    required String title,
    required String subtitle,
    required Widget child,
    bool highlight = false,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: highlight
            ? Theme.of(
                context,
              ).colorScheme.primaryContainer.withValues(alpha: 0.45)
            : Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: highlight
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).dividerColor.withValues(alpha: 0.2),
        ),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          Expanded(child: child),
        ],
      ),
    );
  }

  Widget _emptyPanel(String text) {
    return Center(
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    );
  }
}

class _TrackDraggableTile extends StatelessWidget {
  const _TrackDraggableTile({
    required this.track,
    required this.onToggleLike,
    required this.onBumpPlayCount,
  });

  final AudioTrack track;
  final VoidCallback onToggleLike;
  final VoidCallback onBumpPlayCount;

  @override
  Widget build(BuildContext context) {
    final liked = track.metadataValue<bool>('isLike') ?? false;
    final playCount = track.metadataValue<int>('playCount') ?? 0;
    return Draggable<AudioTrack>(
      data: track,
      feedback: Material(
        color: Colors.transparent,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 280),
          child: _TrackSummaryTile(
            track: track,
            trailing: const Icon(Icons.drag_indicator),
          ),
        ),
      ),
      childWhenDragging: Opacity(
        opacity: 0.5,
        child: _TrackSummaryTile(
          track: track,
          trailing: const Icon(Icons.drag_indicator),
        ),
      ),
      child: _TrackSummaryTile(
        track: track,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: liked ? 'Unmark liked' : 'Mark liked',
              onPressed: onToggleLike,
              icon: Icon(liked ? Icons.favorite : Icons.favorite_border),
            ),
            IconButton(
              tooltip: 'Increment play count',
              onPressed: onBumpPlayCount,
              icon: const Icon(Icons.plus_one),
            ),
            Text('$playCount', style: Theme.of(context).textTheme.labelLarge),
          ],
        ),
      ),
    );
  }
}

class _TrackSummaryTile extends StatelessWidget {
  const _TrackSummaryTile({required this.track, required this.trailing});

  final AudioTrack track;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final liked = track.metadataValue<bool>('isLike') ?? false;
    final playCount = track.metadataValue<int>('playCount') ?? 0;
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
              child: Icon(liked ? Icons.favorite : Icons.music_note, size: 18),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    track.title ?? track.id,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'playCount: $playCount',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            trailing,
          ],
        ),
      ),
    );
  }
}
