import 'package:flutter/foundation.dart';

import 'audio_core_controller_delegate.dart';
import 'player_models.dart';
import 'playlist_models.dart';
import 'random_playback_models.dart';
import 'random_playback_manager.dart';

/// Manages playlists, tracks, and playback order.
class PlaylistController extends ChangeNotifier {
  PlaylistController({required AudioCoreControllerDelegate delegate})
    : _delegate = delegate;

  final AudioCoreControllerDelegate _delegate;

  static const String _defaultPlaylistId = '__default__';
  final List<Playlist> _playlists = <Playlist>[];
  String? _activePlaylistId;

  final List<AudioTrack> _activePlaylistTracks = <AudioTrack>[];
  final List<int> _playOrder = <int>[];
  int? _currentIndex;
  int? _currentOrderCursor;

  PlaylistMode _playlistMode = PlaylistMode.queue;
  final _randomManager = RandomPlaybackManager();

  /// All user-visible playlists.
  List<Playlist> get playlists => List<Playlist>.unmodifiable(
    _playlists.where((p) => p.id != _defaultPlaylistId).toList(),
  );

  /// Current active playlist.
  Playlist? get activePlaylist => playlistById(_activePlaylistId);

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
  RandomPolicy? get randomPolicy => _randomManager.policy;
  String? get activePlaylistId => _activePlaylistId;
  String get queuePlaylistId => _defaultPlaylistId;
  List<RandomHistoryEntry> get randomHistory => _randomManager.history;
  int? get historyCursor => _randomManager.historyCursor;
  List<String> get currentDeck => _randomManager.currentDeck;
  int? get deckCursor => _randomManager.deckCursor;
  String? get deckSignature => _randomManager.deckSignature;
  String? get stashedNextTrackId => _randomManager.stashedNextTrackId;
  String? get stashedForTrackId => _randomManager.stashedForTrackId;

  /// Whether there is a next track available.
  bool get hasNext => nextTrack != null;

  /// Whether there is a previous track available.
  bool get hasPrev => previousTrack != null;

  /// Returns the next track in the current playlist sequence.
  AudioTrack? get nextTrack {
    final index = _resolveAdjacentIndex(next: true, peek: true);
    return (index != null && index >= 0 && index < _activePlaylistTracks.length)
        ? _activePlaylistTracks[index]
        : null;
  }

  /// Returns the previous track in the current playlist sequence.
  AudioTrack? get previousTrack {
    final index = _resolveAdjacentIndex(next: false, peek: true);
    return (index != null && index >= 0 && index < _activePlaylistTracks.length)
        ? _activePlaylistTracks[index]
        : null;
  }

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
  }

  Future<void> removePlaylist(String id) async {
    _playlists.removeWhere((p) => p.id == id);
    if (_activePlaylistId == id) {
      await switchPlaylist(_defaultPlaylistId);
    }
    notifyListeners();
  }

  Future<void> setActivePlaylist(
    String id, {
    int startIndex = 0,
    bool autoPlay = false,
    FadeSettings? fadeSetting,
  }) async {
    final playlist = playlistById(id);
    if (playlist == null) return;

    final oldTrack = currentTrack;
    final isSamePlaylist = _activePlaylistId == id;
    if (isSamePlaylist && _currentIndex == startIndex) {
      await _delegate.loadTrack(
        autoPlay: autoPlay,
        reason: PlaybackReason.playlistChanged,
        fadeSetting: fadeSetting,
      );
      return;
    }

    _activePlaylistId = id;
    if (!isSamePlaylist) {
      _activePlaylistTracks
        ..clear()
        ..addAll(playlist.items);
    }

    _currentIndex = _activePlaylistTracks.isEmpty
        ? null
        : startIndex.clamp(0, _activePlaylistTracks.length - 1).toInt();

    await _reconcile(
      forceLoad: true,
      autoPlay: autoPlay,
      oldTrack: oldTrack,
      fadeSetting: fadeSetting,
    );
  }

  Future<void> switchPlaylist(String id, {FadeSettings? fadeSetting}) async =>
      setActivePlaylist(id, fadeSetting: fadeSetting);

  Future<void> addTracks(
    List<AudioTrack> tracks, {
    FadeSettings? fadeSetting,
  }) async {
    final oldTrack = currentTrack;
    await _ensureDefaultPlaylist();
    _activePlaylistTracks.addAll(tracks);

    if (oldTrack == null && _activePlaylistTracks.isNotEmpty) {
      _currentIndex = 0;
    }

    await _reconcile(oldTrack: oldTrack, fadeSetting: fadeSetting);
  }

  Future<void> addTracksToPlaylist(
    String id,
    List<AudioTrack> tracks, {
    FadeSettings? fadeSetting,
    bool reconcile = true,
  }) async {
    final idx = _playlists.indexWhere((p) => p.id == id);
    if (idx < 0) return;

    _playlists[idx] = _playlists[idx].copyWith(
      items: [..._playlists[idx].items, ...tracks],
    );

    if (_activePlaylistId == id) {
      final oldTrack = currentTrack;
      _activePlaylistTracks.addAll(tracks);
      if (oldTrack == null && _activePlaylistTracks.isNotEmpty) {
        _currentIndex = 0;
      }
      if (reconcile) {
        await _reconcile(oldTrack: oldTrack, fadeSetting: fadeSetting);
      } else {
        await _syncActivePlaylistData();
        _rebuildPlayOrder();
        _reconcileRandom();
        notifyListeners();
      }
    } else {
      notifyListeners(); // Metadata in another playlist changed
    }
  }

  @internal
  Future<void> updatePlaylistTracks(
    String id,
    List<AudioTrack> newTracks, {
    FadeSettings? fadeSetting,
  }) async {
    final idx = _playlists.indexWhere((p) => p.id == id);
    if (idx < 0) return;

    _playlists[idx] = _playlists[idx].copyWith(items: newTracks);
    if (_activePlaylistId == id) {
      final oldTrack = currentTrack;
      final oldId = oldTrack?.id;

      _activePlaylistTracks
        ..clear()
        ..addAll(newTracks);

      if (oldId != null) {
        final newIdx = _activePlaylistTracks.indexWhere((t) => t.id == oldId);
        _currentIndex = newIdx >= 0 ? newIdx : null;
      } else {
        _currentIndex = _activePlaylistTracks.isNotEmpty ? 0 : null;
      }

      await _reconcile(oldTrack: oldTrack, fadeSetting: fadeSetting);
    } else {
      notifyListeners();
    }
  }

  Future<void> insertTrack(
    int index,
    AudioTrack track, {
    FadeSettings? fadeSetting,
  }) async {
    final oldTrack = currentTrack;
    _activePlaylistTracks.insert(index, track);

    if (oldTrack == null) {
      _currentIndex = 0;
    } else if (_currentIndex != null && index <= _currentIndex!) {
      _currentIndex = _currentIndex! + 1;
    }

    await _reconcile(oldTrack: oldTrack, fadeSetting: fadeSetting);
  }

  Future<void> replaceTrack(
    AudioTrack track, {
    FadeSettings? fadeSetting,
  }) async {
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
        await _delegate.loadTrack(
          autoPlay: false,
          reason: PlaybackReason.playlistChanged,
          fadeSetting: fadeSetting,
        );
      }
      notifyListeners();
    }
  }

  Future<bool> playNext({
    PlaybackReason reason = PlaybackReason.user,
    FadeSettings? fadeSetting,
  }) async {
    final oldTrack = currentTrack;
    final resolution = await _resolvePlayableAdjacentIndex(next: true);
    debugPrint(
      '[PlaylistController] playNext reason=$reason '
      'old=${oldTrack?.id} resolution=$resolution '
      'mode=$_playlistMode random=${_randomManager.policy != null}',
    );
    if (resolution == null) return false;
    _currentIndex = resolution;
    await _reconcile(
      oldTrack: oldTrack,
      autoPlay: reason != PlaybackReason.playlistChanged,
      reason: reason,
      fadeSetting: fadeSetting,
    );
    return true;
  }

  Future<bool> playPrevious({
    PlaybackReason reason = PlaybackReason.user,
    FadeSettings? fadeSetting,
  }) async {
    final oldTrack = currentTrack;
    final resolution = await _resolvePlayableAdjacentIndex(next: false);
    debugPrint(
      '[PlaylistController] playPrevious reason=$reason '
      'old=${oldTrack?.id} resolution=$resolution '
      'mode=$_playlistMode random=${_randomManager.policy != null}',
    );
    if (resolution == null) return false;
    _currentIndex = resolution;
    await _reconcile(
      oldTrack: oldTrack,
      autoPlay: reason != PlaybackReason.playlistChanged,
      reason: reason,
      fadeSetting: fadeSetting,
    );
    return true;
  }

  Future<void> moveTrack(
    int oldIndex,
    int newIndex, {
    FadeSettings? fadeSetting,
  }) async {
    if (oldIndex < 0 ||
        oldIndex >= _activePlaylistTracks.length ||
        newIndex < 0 ||
        newIndex >= _activePlaylistTracks.length) {
      return;
    }

    final oldTrack = currentTrack;
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

    await _reconcile(oldTrack: oldTrack, fadeSetting: fadeSetting);
  }

  Future<void> removeTrackAt(int index, {FadeSettings? fadeSetting}) async {
    if (index < 0 || index >= _activePlaylistTracks.length) return;
    final oldTrack = currentTrack;
    final removedCurrent = _currentIndex == index;

    _activePlaylistTracks.removeAt(index);

    if (_activePlaylistTracks.isEmpty) {
      await clear(fadeSetting: fadeSetting);
      return;
    }

    if (removedCurrent) {
      _currentIndex = index.clamp(0, _activePlaylistTracks.length - 1).toInt();
    } else {
      if (_currentIndex != null && index < _currentIndex!) {
        _currentIndex = _currentIndex! - 1;
      }
    }

    await _reconcile(oldTrack: oldTrack, fadeSetting: fadeSetting);
  }

  Future<void> clear({FadeSettings? fadeSetting}) async {
    final oldTrack = currentTrack;
    _activePlaylistTracks.clear();
    _currentIndex = null;
    _randomManager.setPolicy(null);

    await _reconcile(oldTrack: oldTrack, fadeSetting: fadeSetting);
  }

  Future<void> resetPlaybackState() async {
    _playlists.clear();
    _activePlaylistId = null;
    _activePlaylistTracks.clear();
    _playOrder.clear();
    _currentIndex = null;
    _currentOrderCursor = null;
    _playlistMode = PlaylistMode.queue;
    _randomManager.setPolicy(null);
    _randomManager.clearHistory();
    notifyListeners();
  }

  /// Ensures that the default queue playlist exists and is active.
  Future<void> ensureQueuePlaylist() async => _ensureDefaultPlaylist();

  void setMode(PlaylistMode mode) {
    _playlistMode = mode;
    notifyListeners();
  }

  void setShuffle({
    RandomScope? scope,
    RandomStrategy? strategy,
    int avoidRecent = 2,
    int historySize = 200,
    RandomExhaustionPolicy exhaustion = RandomExhaustionPolicy.reshuffle,
    int? seed,
  }) {
    final policy = RandomPolicy(
      scope: scope ?? RandomScope.all(),
      strategy: strategy ?? RandomStrategy.fisherYates(),
      history: RandomHistoryPolicy(
        maxEntries: historySize,
        recentWindow: avoidRecent,
      ),
      exhaustion: exhaustion,
      seed: seed,
      label: 'shuffle',
    );
    _randomManager.setPolicy(policy);
    _reconcileRandom();
    notifyListeners();
  }

  void setWeightedShuffle({
    required String id,
    required double Function(
      AudioTrack track,
      int index,
      RandomSelectionContext context,
    )
    weightOf,
    RandomScope? scope,
    int avoidRecent = 2,
    int historySize = 2400,
    RandomExhaustionPolicy exhaustion = RandomExhaustionPolicy.reshuffle,
    int? seed,
  }) {
    final policy = RandomPolicy.weighted(
      id: id,
      weightOf: weightOf,
      scope: scope,
      recentWindow: avoidRecent,
      maxEntries: historySize,
      exhaustion: exhaustion,
      seed: seed,
    );
    _randomManager.setPolicy(policy);
    _reconcileRandom();
    notifyListeners();
  }

  void clearShuffle() => setRandomPolicy(null);

  void clearRandomHistory() {
    _randomManager.clearHistory();
    notifyListeners();
  }

  void clearShuffleHistory() => clearRandomHistory();

  void setRandomPolicy(RandomPolicy? policy) {
    _randomManager.setPolicy(policy);
    _reconcileRandom();
    notifyListeners();
  }

  void restoreRandomPlaybackState({
    required RandomPolicy? policy,
    List<RandomHistoryEntry> history = const <RandomHistoryEntry>[],
    int? historyCursor,
    List<String> deck = const <String>[],
    int? deckCursor,
    String? deckSignature,
    String? stashedNextTrackId,
    String? stashedForTrackId,
  }) {
    _randomManager.restoreState(
      policy: policy,
      history: history,
      historyCursor: historyCursor,
      deck: deck,
      deckCursor: deckCursor,
      deckSignature: deckSignature,
      stashedNextTrackId: stashedNextTrackId,
      stashedForTrackId: stashedForTrackId,
    );
    notifyListeners();
  }

  @internal
  int? resolveAdjacentIndex({required bool next}) =>
      _resolveAdjacentIndex(next: next, peek: true);

  // --- Internal ---

  Future<int?> _resolvePlayableAdjacentIndex({required bool next}) async {
    if (_activePlaylistTracks.isEmpty || _playlistMode == PlaylistMode.single) {
      return null;
    }

    if (_playlistMode == PlaylistMode.singleLoop) {
      final index = _currentIndex ?? 0;
      final playable = await _isPlayableIndex(index);
      return playable ? index : null;
    }

    if (_randomManager.policy != null) {
      final snapshot = _captureRandomState();
      final maxAttempts = _activePlaylistTracks.length;
      int? resolution;
      var foundPlayable = false;

      try {
        for (var attempts = 0; attempts < maxAttempts; attempts++) {
          resolution = _randomManager.resolveAdjacentIndex(
            next: next,
            playlistId: _activePlaylistId,
            tracks: _activePlaylistTracks,
            currentTrack: currentTrack,
            loop:
                _playlistMode == PlaylistMode.queueLoop ||
                _playlistMode == PlaylistMode.autoQueueLoop,
            peek: false,
          );
          if (resolution == null) {
            break;
          }

          if (await _isPlayableIndex(resolution)) {
            foundPlayable = true;
            break;
          }
        }
      } finally {
        if (!foundPlayable &&
            (_randomManager.currentDeck != snapshot.deck ||
                _randomManager.historyCursor != snapshot.historyCursor ||
                _randomManager.deckCursor != snapshot.deckCursor ||
                _randomManager.deckSignature != snapshot.deckSignature ||
                _randomManager.stashedNextTrackId !=
                    snapshot.stashedNextTrackId ||
                _randomManager.stashedForTrackId !=
                    snapshot.stashedForTrackId)) {
          _randomManager.restoreState(
            policy: snapshot.policy,
            history: snapshot.history,
            historyCursor: snapshot.historyCursor,
            deck: snapshot.deck,
            deckCursor: snapshot.deckCursor,
            deckSignature: snapshot.deckSignature,
            stashedNextTrackId: snapshot.stashedNextTrackId,
            stashedForTrackId: snapshot.stashedForTrackId,
          );
        }
      }

      return foundPlayable ? resolution : null;
    }

    return next
        ? await _resolveSequentialPlayableIndex(next: true)
        : await _resolveSequentialPlayableIndex(next: false);
  }

  Future<int?> _resolveSequentialPlayableIndex({required bool next}) async {
    if (_activePlaylistTracks.isEmpty) return null;

    if (_currentIndex == null) {
      if (!next) return null;
      for (var i = 0; i < _activePlaylistTracks.length; i++) {
        if (await _isPlayableIndex(i)) return i;
      }
      return null;
    }

    final length = _activePlaylistTracks.length;
    if (length == 0) return null;

    final loop =
        _playlistMode == PlaylistMode.queueLoop ||
        _playlistMode == PlaylistMode.autoQueueLoop;
    var steps = 0;
    var index = _currentIndex!;

    while (steps < length) {
      index = next ? index + 1 : index - 1;
      steps++;

      if (index < 0 || index >= length) {
        if (!loop) return null;
        index = (index + length) % length;
      }

      if (index == _currentIndex!) {
        return null;
      }

      if (await _isPlayableIndex(index)) {
        return index;
      }
    }

    return null;
  }

  Future<bool> _isPlayableIndex(int index) async {
    if (index < 0 || index >= _activePlaylistTracks.length) {
      return false;
    }
    final track = _activePlaylistTracks[index];
    return _isPlayableTrack(track);
  }

  Future<bool> _isPlayableTrack(AudioTrack track) async =>
      await _delegate.canPlayTrack(track);

  _RandomStateSnapshot _captureRandomState() {
    return _RandomStateSnapshot(
      policy: _randomManager.policy,
      history: List<RandomHistoryEntry>.unmodifiable(_randomManager.history),
      historyCursor: _randomManager.historyCursor,
      deck: List<String>.unmodifiable(_randomManager.currentDeck),
      deckCursor: _randomManager.deckCursor,
      deckSignature: _randomManager.deckSignature,
      stashedNextTrackId: _randomManager.stashedNextTrackId,
      stashedForTrackId: _randomManager.stashedForTrackId,
    );
  }

  int? _resolveAdjacentIndex({required bool next, bool peek = false}) {
    if (_activePlaylistTracks.isEmpty || _playlistMode == PlaylistMode.single) {
      return null;
    }
    if (_playlistMode == PlaylistMode.singleLoop) return _currentIndex ?? 0;

    if (_randomManager.policy != null) {
      return _randomManager.resolveAdjacentIndex(
        next: next,
        playlistId: _activePlaylistId,
        tracks: _activePlaylistTracks,
        currentTrack: currentTrack,
        loop:
            _playlistMode == PlaylistMode.queueLoop ||
            _playlistMode == PlaylistMode.autoQueueLoop,
        peek: peek,
      );
    }

    return _resolveSequentialAdjacentIndex(next: next);
  }

  int? _resolveSequentialAdjacentIndex({required bool next}) {
    if (_playOrder.isEmpty) return null;
    if (_currentIndex == null) return 0;

    final cursor = _currentOrderCursor ?? _playOrder.indexOf(_currentIndex!);
    if (cursor < 0) return 0;

    if (next) {
      if (cursor < _playOrder.length - 1) return _playOrder[cursor + 1];
      if (_playlistMode == PlaylistMode.queueLoop ||
          _playlistMode == PlaylistMode.autoQueueLoop) {
        return _playOrder[0];
      }
      return null;
    }

    if (cursor > 0) return _playOrder[cursor - 1];
    if (_playlistMode == PlaylistMode.queueLoop ||
        _playlistMode == PlaylistMode.autoQueueLoop) {
      return _playOrder.last;
    }
    return null;
  }

  void _syncOrderCursor() {
    if (_currentIndex == null) {
      _currentOrderCursor = null;
    } else {
      final cursor = _playOrder.indexOf(_currentIndex!);
      _currentOrderCursor = cursor >= 0 ? cursor : null;
    }
  }

  void _reconcileRandom() {
    _randomManager.reconcile(
      playlistId: _activePlaylistId,
      tracks: _activePlaylistTracks,
      currentTrack: currentTrack,
      currentIndex: _currentIndex,
    );
  }

  /// Reconciles state after a modification and notifies.
  Future<void> _reconcile({
    bool forceLoad = false,
    bool autoPlay = false,
    AudioTrack? oldTrack,
    PlaybackReason reason = PlaybackReason.playlistChanged,
    FadeSettings? fadeSetting,
  }) async {
    _rebuildPlayOrder();
    _reconcileRandom();
    await _syncActivePlaylistData();

    final track = currentTrack;
    debugPrint(
      '[PlaylistController] reconcile forceLoad=$forceLoad autoPlay=$autoPlay '
      'reason=$reason old=${oldTrack?.id} current=${track?.id} '
      'currentIndex=$_currentIndex playOrder=$_playOrder',
    );
    bool shouldLoad = forceLoad;
    if (!shouldLoad) {
      if (oldTrack == null && track != null) {
        shouldLoad = true;
      } else if (oldTrack != null && track != null && oldTrack.id != track.id) {
        shouldLoad = true;
      }
    }

    if (shouldLoad && track != null) {
      await _delegate.loadTrack(
        autoPlay: autoPlay,
        reason: reason,
        fadeSetting: fadeSetting,
      );
    } else if (oldTrack != null && track == null) {
      await _delegate.clearPlayback();
    }

    notifyListeners();
  }

  Future<void> _syncActivePlaylistData() async {
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
        Playlist(id: _defaultPlaylistId, name: 'Queue', items: []),
      );
    }
    _activePlaylistId = _defaultPlaylistId;
  }

  void _rebuildPlayOrder() {
    _playOrder
      ..clear()
      ..addAll(List<int>.generate(_activePlaylistTracks.length, (i) => i));
    _syncOrderCursor();
  }

  @override
  void notifyListeners() {
    super.notifyListeners();
    _delegate.notifyListeners();
  }
}

class _RandomStateSnapshot {
  const _RandomStateSnapshot({
    required this.policy,
    required this.history,
    required this.historyCursor,
    required this.deck,
    required this.deckCursor,
    required this.deckSignature,
    required this.stashedNextTrackId,
    required this.stashedForTrackId,
  });

  final RandomPolicy? policy;
  final List<RandomHistoryEntry> history;
  final int? historyCursor;
  final List<String> deck;
  final int? deckCursor;
  final String? deckSignature;
  final String? stashedNextTrackId;
  final String? stashedForTrackId;
}
