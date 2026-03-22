import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'playlist_models.dart';
import 'random_playback_models.dart';

/// Manages playlists, tracks, and playback order.
class PlaylistController extends ChangeNotifier {
  PlaylistController({
    required Future<void> Function({required bool autoPlay, Duration? position})
    onLoadTrack,
    required Future<void> Function() onClearPlayback,
    required void Function() onNotifyParent,
  }) : _onLoadTrack = onLoadTrack,
       _onClearPlayback = onClearPlayback,
       _onNotifyParent = onNotifyParent;

  final Future<void> Function({required bool autoPlay, Duration? position})
  _onLoadTrack;
  final Future<void> Function() _onClearPlayback;
  final void Function() _onNotifyParent;

  static const String _defaultPlaylistId = '__default__';
  final List<Playlist> _playlists = <Playlist>[];
  String? _activePlaylistId;

  final List<AudioTrack> _activePlaylistTracks = <AudioTrack>[];
  final List<int> _playOrder = <int>[];
  int? _currentIndex;
  int? _currentOrderCursor;

  PlaylistMode _playlistMode = PlaylistMode.queue;
  RandomPolicy? _randomPolicy;
  math.Random _random = math.Random();
  final List<RandomHistoryEntry> _randomHistory = <RandomHistoryEntry>[];
  int? _randomHistoryCursor;

  /// All user-visible playlists.
  List<Playlist> get playlists => List<Playlist>.unmodifiable(
    _playlists.where((p) => p.id != _defaultPlaylistId).toList(),
  );

  /// Current active playlist.
  Playlist? get activePlaylist {
    return playlistById(_activePlaylistId);
  }

  /// Current active tracks.
  List<AudioTrack> get items =>
      List<AudioTrack>.unmodifiable(_activePlaylistTracks);

  /// 当前播放项在活动列表中的索引。
  int? get currentIndex => _currentIndex;

  /// 当前正在播放的歌曲。
  AudioTrack? get currentTrack =>
      _currentIndex == null || _currentIndex! >= _activePlaylistTracks.length
      ? null
      : _activePlaylistTracks[_currentIndex!];

  /// 当前播放模式。
  PlaylistMode get mode => _playlistMode;

  /// Active random policy, or `null` if sequential playback is used.
  RandomPolicy? get randomPolicy => _randomPolicy;

  /// Legacy convenience alias for random mode.
  bool get shuffleEnabled => _randomPolicy != null;

  /// Stable id for the built-in queue playlist.
  String get queuePlaylistId => _defaultPlaylistId;

  String? get activePlaylistId => _activePlaylistId;

  /// Random history snapshot for UI/debugging.
  List<RandomHistoryEntry> get randomHistory =>
      List<RandomHistoryEntry>.unmodifiable(_randomHistory);

  /// Returns a playlist by id, or `null` if it does not exist.
  Playlist? playlistById(String? id) {
    if (id == null) return null;
    for (final playlist in _playlists) {
      if (playlist.id == id) return playlist;
    }
    return null;
  }

  // --- Methods ---

  Future<void> createPlaylist(
    String id,
    String name, {
    List<AudioTrack> items = const [],
  }) async {
    if (id == _defaultPlaylistId) throw StateError('Reserved ID');
    if (_playlists.any((p) => p.id == id)) throw StateError('Exists');
    _playlists.add(Playlist(id: id, name: name, items: items));
    notifyListeners();
    _onNotifyParent();
  }

  Future<void> setActivePlaylist(
    String id, {
    int startIndex = 0,
    bool autoPlay = false,
  }) async {
    final pl = _playlists.firstWhere(
      (p) => p.id == id,
      orElse: () => throw StateError('Not found'),
    );
    _activePlaylistId = id;
    _activePlaylistTracks
      ..clear()
      ..addAll(pl.items);

    if (_activePlaylistTracks.isEmpty) {
      _currentIndex = null;
    } else {
      _currentIndex = startIndex
          .clamp(0, _activePlaylistTracks.length - 1)
          .toInt();
    }

    _rebuildPlayOrder();
    reconcileRandomState();
    if (_currentIndex != null) {
      await _onLoadTrack(autoPlay: autoPlay);
    }
    notifyListeners();
    _onNotifyParent();
  }

  Future<void> addTrack(AudioTrack track) async {
    if (_activePlaylistId == null) await _ensureDefaultPlaylist();
    _activePlaylistTracks.add(track);
    if (_currentIndex == null) {
      _currentIndex = 0;
      _rebuildPlayOrder();
      reconcileRandomState();
      await _onLoadTrack(autoPlay: false);
    } else {
      _rebuildPlayOrder();
      reconcileRandomState();
    }
    await _syncActivePlaylist();
    notifyListeners();
    _onNotifyParent();
  }

  Future<void> addTracks(List<AudioTrack> tracks) async {
    if (tracks.isEmpty) return;
    if (_activePlaylistId == null) await _ensureDefaultPlaylist();
    final wasEmpty = _activePlaylistTracks.isEmpty;
    _activePlaylistTracks.addAll(tracks);
    if (wasEmpty) {
      _currentIndex = 0;
      _rebuildPlayOrder();
      reconcileRandomState();
      await _onLoadTrack(autoPlay: false);
    } else {
      _rebuildPlayOrder();
      reconcileRandomState();
    }
    await _syncActivePlaylist();
    notifyListeners();
    _onNotifyParent();
  }

  Future<void> addTrackToPlaylist(String playlistId, AudioTrack track) async {
    await addTracksToPlaylist(playlistId, <AudioTrack>[track]);
  }

  Future<void> addTracksToPlaylist(
    String playlistId,
    List<AudioTrack> tracks,
  ) async {
    if (tracks.isEmpty) return;

    if (_activePlaylistId == playlistId) {
      await addTracks(tracks);
      return;
    }

    final idx = _playlists.indexWhere((playlist) => playlist.id == playlistId);
    if (idx < 0) throw StateError('Playlist not found');

    _playlists[idx] = _playlists[idx].copyWith(
      items: <AudioTrack>[..._playlists[idx].items, ...tracks],
    );
    notifyListeners();
    _onNotifyParent();
  }

  Future<void> replaceTrack(AudioTrack track) async {
    var changed = false;

    for (var i = 0; i < _activePlaylistTracks.length; i++) {
      if (_activePlaylistTracks[i].id == track.id) {
        _activePlaylistTracks[i] = track;
        changed = true;
      }
    }

    for (var i = 0; i < _playlists.length; i++) {
      final items = _playlists[i].items;
      var replacedAny = false;
      final replaced = <AudioTrack>[];
      for (final item in items) {
        if (item.id == track.id) {
          replaced.add(track);
          replacedAny = true;
        } else {
          replaced.add(item);
        }
      }
      if (replacedAny) {
        _playlists[i] = _playlists[i].copyWith(items: replaced);
        changed = true;
      }
    }

    if (changed) {
      final current = currentTrack;
      if (current != null &&
          current.id == track.id &&
          current.uri != track.uri) {
        await _onLoadTrack(autoPlay: false);
      }
      notifyListeners();
      _onNotifyParent();
    }
  }

  /// 跳到下一首，随机模式下会优先沿用随机历史。
  Future<bool> playNext({PlaybackReason reason = PlaybackReason.user}) async {
    final resolution = _resolveAdjacentIndex(next: true);
    if (resolution.index == null) return false;
    _currentIndex = resolution.index;
    _afterCurrentIndexChanged(resolution);
    await _onLoadTrack(autoPlay: reason != PlaybackReason.playlistChanged);
    notifyListeners();
    _onNotifyParent();
    return true;
  }

  /// 跳到上一首，随机模式下会回退随机历史。
  Future<bool> playPrevious({
    PlaybackReason reason = PlaybackReason.user,
  }) async {
    final resolution = _resolveAdjacentIndex(next: false);
    if (resolution.index == null) return false;
    _currentIndex = resolution.index;
    _afterCurrentIndexChanged(resolution);
    await _onLoadTrack(autoPlay: reason != PlaybackReason.playlistChanged);
    notifyListeners();
    _onNotifyParent();
    return true;
  }

  Future<void> moveTrack(int oldIndex, int newIndex) async {
    if (oldIndex < 0 ||
        oldIndex >= _activePlaylistTracks.length ||
        newIndex < 0 ||
        newIndex >= _activePlaylistTracks.length) {
      return;
    }

    final track = _activePlaylistTracks.removeAt(oldIndex);
    _activePlaylistTracks.insert(newIndex, track);

    if (_currentIndex != null) {
      if (_currentIndex == oldIndex) {
        _currentIndex = newIndex;
      } else if (oldIndex < _currentIndex! && newIndex >= _currentIndex!) {
        _currentIndex = _currentIndex! - 1;
      } else if (oldIndex > _currentIndex! && newIndex <= _currentIndex!) {
        _currentIndex = _currentIndex! + 1;
      }
    }

    _rebuildPlayOrder();
    reconcileRandomState();
    await _syncActivePlaylist();
    notifyListeners();
    _onNotifyParent();
  }

  Future<void> removeTrackAt(int index) async {
    if (index < 0 || index >= _activePlaylistTracks.length) return;
    final removedCurrent = _currentIndex == index;
    _activePlaylistTracks.removeAt(index);

    if (_activePlaylistTracks.isEmpty) {
      await clear();
      return;
    }

    if (removedCurrent) {
      _currentIndex = index.clamp(0, _activePlaylistTracks.length - 1).toInt();
      _rebuildPlayOrder();
      reconcileRandomState();
      await _onLoadTrack(autoPlay: false);
    } else {
      if (_currentIndex != null && index < _currentIndex!) {
        _currentIndex = _currentIndex! - 1;
      }
      _rebuildPlayOrder();
      reconcileRandomState();
    }
    await _syncActivePlaylist();
    notifyListeners();
    _onNotifyParent();
  }

  /// 清空当前播放列表和播放状态。
  Future<void> clear() async {
    _activePlaylistTracks.clear();
    _playOrder.clear();
    _currentIndex = null;
    _currentOrderCursor = null;
    _randomHistory.clear();
    _randomHistoryCursor = null;
    await _onClearPlayback();
    await _syncActivePlaylist();
    notifyListeners();
    _onNotifyParent();
  }

  /// 确保内置队列播放列表已创建。
  Future<void> ensureQueuePlaylist() async {
    await _ensureDefaultPlaylist();
  }

  /// 设置顺序播放模式。
  void setMode(PlaylistMode mode) {
    _playlistMode = mode;
    notifyListeners();
    _onNotifyParent();
  }

  /// Preset for standard shuffle behavior on the active track list.
  /// 开关式随机：开启时使用整表随机，关闭时恢复顺序播放。
  void setShuffle(bool enabled) {
    setRandomPolicy(enabled ? RandomPolicy.uniformAll() : null);
  }

  /// 设置完整随机策略。
  void setRandomPolicy(RandomPolicy? policy) {
    if (_randomPolicy?.key == policy?.key) return;
    _randomPolicy = policy;
    _random = policy == null
        ? math.Random()
        : (policy.seed == null ? math.Random() : math.Random(policy.seed!));
    _randomHistory.clear();
    _randomHistoryCursor = null;
    reconcileRandomState();
    notifyListeners();
    _onNotifyParent();
  }

  /// 清除随机历史，但保留当前随机策略。
  void clearRandomHistory() {
    _randomHistory.clear();
    _randomHistoryCursor = null;
    notifyListeners();
    _onNotifyParent();
  }

  /// 让随机历史与当前播放状态对齐。
  void reconcileRandomState() {
    if (_randomPolicy == null) {
      _randomHistory.clear();
      _randomHistoryCursor = null;
      return;
    }

    _trimRandomHistoryToPolicy();

    final current = currentTrack;
    if (current == null) {
      _randomHistoryCursor = null;
      return;
    }

    final cursor = _findLastHistoryCursorForTrackId(current.id);
    if (cursor != null) {
      _randomHistoryCursor = cursor;
    } else {
      _appendCurrentTrackToRandomHistory(forceAppend: true);
    }

    _trimRandomHistoryToPolicy();
  }

  /// 仅计算下一首或上一首索引，不真正切歌。
  int? resolveAdjacentIndex({required bool next}) {
    return _resolveAdjacentIndex(next: next).index;
  }

  /// 把当前索引同步到顺序播放游标。
  void syncOrderCursorFromCurrentIndex() {
    if (_currentIndex == null) {
      _currentOrderCursor = null;
      return;
    }
    final cursor = _playOrder.indexOf(_currentIndex!);
    _currentOrderCursor = cursor >= 0 ? cursor : null;
  }

  /// 直接更新当前索引，并同步相关状态。
  void updateCurrentIndex(int? index) {
    _currentIndex = index;
    syncOrderCursorFromCurrentIndex();
    reconcileRandomState();
  }

  // --- Internal ---

  _NavigationResolution _resolveAdjacentIndex({required bool next}) {
    if (_activePlaylistTracks.isEmpty) {
      return const _NavigationResolution(index: null);
    }

    if (_playlistMode == PlaylistMode.single) {
      return const _NavigationResolution(index: null);
    }

    if (_playlistMode == PlaylistMode.singleLoop) {
      return _NavigationResolution(
        index: _currentIndex ?? 0,
        fromHistory: false,
      );
    }

    if (_randomPolicy != null) {
      return _resolveRandomAdjacentIndex(next: next);
    }

    return _resolveSequentialAdjacentIndex(next: next);
  }

  _NavigationResolution _resolveSequentialAdjacentIndex({required bool next}) {
    if (_playOrder.isEmpty) return const _NavigationResolution(index: null);
    if (_currentIndex == null) return const _NavigationResolution(index: 0);

    final cursor = _currentOrderCursor ?? _playOrder.indexOf(_currentIndex!);
    if (cursor < 0) {
      return const _NavigationResolution(index: 0);
    }

    if (next) {
      if (cursor < _playOrder.length - 1) {
        return _NavigationResolution(
          index: _playOrder[cursor + 1],
          fromHistory: false,
        );
      }
      if (_playlistMode == PlaylistMode.queueLoop ||
          _playlistMode == PlaylistMode.autoQueueLoop) {
        return _NavigationResolution(index: _playOrder[0], fromHistory: false);
      }
      return const _NavigationResolution(index: null);
    }

    if (cursor > 0) {
      return _NavigationResolution(
        index: _playOrder[cursor - 1],
        fromHistory: false,
      );
    }
    if (_playlistMode == PlaylistMode.queueLoop ||
        _playlistMode == PlaylistMode.autoQueueLoop) {
      return _NavigationResolution(index: _playOrder.last, fromHistory: false);
    }
    return const _NavigationResolution(index: null);
  }

  _NavigationResolution _resolveRandomAdjacentIndex({required bool next}) {
    if (_currentIndex == null) {
      final picked = _pickRandomCandidateIndex();
      return _NavigationResolution(
        index: picked,
        fromHistory: false,
        shouldRecord: picked != null,
      );
    }

    final cursor = _randomHistoryCursor ?? _findHistoryCursorForCurrentTrack();
    if (cursor != null) {
      _randomHistoryCursor = cursor;
      if (next && cursor < _randomHistory.length - 1) {
        return _NavigationResolution(
          index: _randomHistory[cursor + 1].trackIndex,
          fromHistory: true,
          historyCursor: cursor + 1,
        );
      }
      if (!next && cursor > 0) {
        return _NavigationResolution(
          index: _randomHistory[cursor - 1].trackIndex,
          fromHistory: true,
          historyCursor: cursor - 1,
        );
      }
      if (!next &&
          cursor == 0 &&
          (_playlistMode == PlaylistMode.queueLoop ||
              _playlistMode == PlaylistMode.autoQueueLoop) &&
          _randomHistory.isNotEmpty) {
        return _NavigationResolution(
          index: _randomHistory.last.trackIndex,
          fromHistory: true,
          historyCursor: _randomHistory.length - 1,
        );
      }
    }

    if (!next) {
      if (_playlistMode == PlaylistMode.queueLoop ||
          _playlistMode == PlaylistMode.autoQueueLoop) {
        if (_randomHistory.isNotEmpty) {
          return _NavigationResolution(
            index: _randomHistory.last.trackIndex,
            fromHistory: true,
            historyCursor: _randomHistory.length - 1,
          );
        }
      }
      return const _NavigationResolution(index: null);
    }

    final picked = _pickRandomCandidateIndex();
    return _NavigationResolution(
      index: picked,
      fromHistory: false,
      shouldRecord: picked != null,
    );
  }

  int? _pickRandomCandidateIndex() {
    if (_randomPolicy == null || _activePlaylistTracks.isEmpty) return null;
    final policy = _randomPolicy!;
    final context = _buildRandomSelectionContext(policy.key);
    final candidates = _resolveRandomCandidates(context, policy);
    if (candidates.isEmpty) return null;
    return policy.strategy.select(_random, candidates, context);
  }

  List<int> _resolveRandomCandidates(
    RandomSelectionContext context,
    RandomPolicy policy,
  ) {
    final candidates = policy.scope.resolve(context);
    if (candidates.isEmpty) return candidates;

    final recentIds = _recentTrackIds(policy.history.recentWindow);
    if (recentIds.isEmpty) return candidates;

    final filtered = candidates
        .where((index) {
          final track = context.trackAt(index);
          return track != null && !recentIds.contains(track.id);
        })
        .toList(growable: false);

    return filtered.isEmpty ? candidates : filtered;
  }

  Set<String> _recentTrackIds(int window) {
    if (window <= 0 || _randomHistory.isEmpty) {
      return const <String>{};
    }
    final start = _randomHistory.length - window;
    final begin = start < 0 ? 0 : start;
    final ids = <String>{};
    for (var i = begin; i < _randomHistory.length; i++) {
      ids.add(_randomHistory[i].trackId);
    }
    return ids;
  }

  RandomSelectionContext _buildRandomSelectionContext(String policyKey) {
    return RandomSelectionContext(
      playlistId: _activePlaylistId,
      tracks: List<AudioTrack>.unmodifiable(_activePlaylistTracks),
      currentIndex: _currentIndex,
      history: List<RandomHistoryEntry>.unmodifiable(_randomHistory),
      policyKey: policyKey,
    );
  }

  void _afterCurrentIndexChanged(_NavigationResolution resolution) {
    syncOrderCursorFromCurrentIndex();
    if (_randomPolicy == null) return;

    if (resolution.fromHistory && resolution.historyCursor != null) {
      _randomHistoryCursor = resolution.historyCursor;
      return;
    }

    if (resolution.shouldRecord) {
      _appendCurrentTrackToRandomHistory(forceAppend: false);
      return;
    }

    reconcileRandomState();
  }

  void _appendCurrentTrackToRandomHistory({required bool forceAppend}) {
    if (_randomPolicy == null || _currentIndex == null) return;
    final current = currentTrack;
    if (current == null) return;

    final policy = _randomPolicy!;
    if (policy.history.maxEntries == 0) {
      _randomHistory.clear();
      _randomHistoryCursor = null;
      return;
    }

    if (_randomHistoryCursor != null &&
        _randomHistoryCursor! < _randomHistory.length - 1) {
      _randomHistory.removeRange(
        _randomHistoryCursor! + 1,
        _randomHistory.length,
      );
    }

    if (!forceAppend && _randomHistory.isNotEmpty) {
      final last = _randomHistory.last;
      if (last.trackId == current.id &&
          last.playlistId == _activePlaylistId &&
          last.trackIndex == _currentIndex) {
        _randomHistoryCursor = _randomHistory.length - 1;
        return;
      }
    }

    _randomHistory.add(
      RandomHistoryEntry(
        trackId: current.id,
        playlistId: _activePlaylistId,
        trackIndex: _currentIndex!,
        generatedAt: DateTime.now(),
        policyKey: policy.key,
      ),
    );

    _randomHistoryCursor = _randomHistory.length - 1;
    _trimRandomHistoryToPolicy();
  }

  void _trimRandomHistoryToPolicy() {
    if (_randomPolicy == null) return;
    final maxEntries = _randomPolicy!.history.maxEntries;
    if (maxEntries <= 0) {
      _randomHistory.clear();
      _randomHistoryCursor = null;
      return;
    }

    final overflow = _randomHistory.length - maxEntries;
    if (overflow > 0) {
      _randomHistory.removeRange(0, overflow);
      if (_randomHistoryCursor != null) {
        _randomHistoryCursor = (_randomHistoryCursor! - overflow)
            .clamp(0, _randomHistory.length - 1)
            .toInt();
      }
    }
    if (_randomHistory.isEmpty) {
      _randomHistoryCursor = null;
    } else if (_randomHistoryCursor != null &&
        _randomHistoryCursor! >= _randomHistory.length) {
      _randomHistoryCursor = _randomHistory.length - 1;
    }
  }

  int? _findHistoryCursorForCurrentTrack() {
    final current = currentTrack;
    if (current == null) return null;
    return _findLastHistoryCursorForTrackId(current.id);
  }

  int? _findLastHistoryCursorForTrackId(String trackId) {
    for (var i = _randomHistory.length - 1; i >= 0; i--) {
      if (_randomHistory[i].trackId == trackId) {
        return i;
      }
    }
    return null;
  }

  Future<void> _syncActivePlaylist() async {
    if (_activePlaylistId == null) return;
    final idx = _playlists.indexWhere((p) => p.id == _activePlaylistId);
    if (idx >= 0) {
      _playlists[idx] = _playlists[idx].copyWith(
        items: List.from(_activePlaylistTracks),
      );
    }
  }

  Future<void> _ensureDefaultPlaylist() async {
    if (_activePlaylistId != null) return;
    if (!_playlists.any((p) => p.id == _defaultPlaylistId)) {
      _playlists.add(
        const Playlist(id: _defaultPlaylistId, name: 'Queue', items: []),
      );
    }
    _activePlaylistId = _defaultPlaylistId;
  }

  void _rebuildPlayOrder() {
    _playOrder
      ..clear()
      ..addAll(List<int>.generate(_activePlaylistTracks.length, (i) => i));
    syncOrderCursorFromCurrentIndex();
  }
}

class _NavigationResolution {
  const _NavigationResolution({
    required this.index,
    this.fromHistory = false,
    this.historyCursor,
    this.shouldRecord = false,
  });

  final int? index;
  final bool fromHistory;
  final int? historyCursor;
  final bool shouldRecord;
}
