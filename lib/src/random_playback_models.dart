import 'dart:math' as math;

import 'playlist_models.dart';

/// Context made available to random scopes and strategies.
class RandomSelectionContext {
  const RandomSelectionContext({
    required this.playlistId,
    required this.tracks,
    required this.currentIndex,
    required this.history,
    required this.policyKey,
  });

  /// 当前播放列表的 id；没有绑定播放列表时为 `null`。
  final String? playlistId;

  /// 当前可参与随机抽取的歌曲列表。
  final List<AudioTrack> tracks;

  /// 当前播放项在 `tracks` 中的索引。
  final int? currentIndex;

  /// 当前随机播放历史，用于前进/后退。
  final List<RandomHistoryEntry> history;

  /// 当前随机策略的唯一标识。
  final String policyKey;

  /// 按索引获取歌曲，越界时返回 `null`。
  AudioTrack? trackAt(int index) {
    if (index < 0 || index >= tracks.length) return null;
    return tracks[index];
  }

  /// 返回指定歌曲 id 在当前列表中的索引，找不到时返回 `-1`。
  int indexOfTrackId(String trackId) =>
      tracks.indexWhere((track) => track.id == trackId);

  /// 判断当前列表里是否包含指定歌曲 id。
  bool containsTrackId(String trackId) => indexOfTrackId(trackId) >= 0;
}

/// Describes the candidate set a random policy can draw from.
abstract class RandomScope {
  const RandomScope();

  /// 该范围的稳定标识，用于调试和历史记录。
  String get key;

  /// 根据当前上下文生成可选候选项索引列表。
  List<int> resolve(RandomSelectionContext context);

  /// 在当前列表内随机抽取所有歌曲。
  factory RandomScope.all() => const _AllRandomScope();

  /// 只在指定播放列表内随机抽取。
  factory RandomScope.playlist(String playlistId) =>
      _PlaylistRandomScope(playlistId);

  /// 只在指定索引区间内随机抽取。
  factory RandomScope.range({
    required int startInclusive,
    required int endExclusive,
  }) => _RangeRandomScope(startInclusive, endExclusive);

  /// 只在给定歌曲 id 集合内随机抽取。
  factory RandomScope.trackIds(Set<String> trackIds) =>
      _TrackIdsRandomScope(Set<String>.unmodifiable(trackIds));

  /// 只在满足自定义条件的歌曲里随机抽取。
  factory RandomScope.filtered({
    required String id,
    required bool Function(
      AudioTrack track,
      int index,
      RandomSelectionContext context,
    )
    predicate,
  }) => _PredicateRandomScope(id, predicate);
}

/// Describes how a random candidate is selected from the scope.
abstract class RandomStrategy {
  const RandomStrategy();

  /// 该策略的稳定标识，用于调试和历史记录。
  String get key;

  /// 从候选项中选出最终播放的索引。
  int select(
    math.Random random,
    List<int> candidates,
    RandomSelectionContext context,
  );

  /// 采用等概率方式随机选取。
  factory RandomStrategy.uniform() => const _UniformRandomStrategy();

  /// 按自定义权重随机选取。
  factory RandomStrategy.weighted({
    required String id,
    required double Function(
      AudioTrack track,
      int index,
      RandomSelectionContext context,
    )
    weightOf,
  }) => _WeightedRandomStrategy(id, weightOf);

  /// 由调用方完全决定最终选项。
  factory RandomStrategy.callback({
    required String id,
    required int Function(
      math.Random random,
      List<int> candidates,
      RandomSelectionContext context,
    )
    select,
  }) => _CallbackRandomStrategy(id, select);
}

/// How much random history should be retained.
class RandomHistoryPolicy {
  const RandomHistoryPolicy({this.maxEntries = 128, this.recentWindow = 1})
    : assert(maxEntries >= 0),
      assert(recentWindow >= 0);

  const RandomHistoryPolicy.disabled() : maxEntries = 0, recentWindow = 0;

  /// 最多保留多少条随机历史。
  final int maxEntries;

  /// 最近多少首歌会被优先排除，避免连续重复。
  final int recentWindow;

  /// 当前历史配置的稳定标识。
  String get key => 'max:$maxEntries|recent:$recentWindow';
}

/// One random playback decision stored for back/forward navigation.
class RandomHistoryEntry {
  const RandomHistoryEntry({
    required this.trackId,
    required this.playlistId,
    required this.trackIndex,
    required this.generatedAt,
    required this.policyKey,
  });

  /// 被选中的歌曲 id。
  final String trackId;

  /// 生成这次选择时所在的播放列表 id。
  final String? playlistId;

  /// 被选中歌曲在当时列表中的索引。
  final int trackIndex;

  /// 这次随机结果的生成时间。
  final DateTime generatedAt;

  /// 生成这条历史记录时使用的策略标识。
  final String policyKey;
}

/// A full random playback policy.
class RandomPolicy {
  const RandomPolicy({
    required this.scope,
    required this.strategy,
    this.history = const RandomHistoryPolicy(),
    this.seed,
    this.label,
  });

  /// 负责筛选候选项的范围。
  final RandomScope scope;

  /// 负责从候选项中挑选最终结果的策略。
  final RandomStrategy strategy;

  /// 随机历史保留规则。
  final RandomHistoryPolicy history;

  /// 可选固定随机种子，便于复现结果。
  final int? seed;

  /// 该策略在 UI 或调试中的显示名称。
  final String? label;

  /// 当前策略的完整标识，包含范围、策略、历史和种子。
  String get key =>
      '${label ?? 'custom'}|${scope.key}|${strategy.key}|${history.key}|seed:${seed ?? 'none'}';

  /// 对整个当前列表做等概率随机。
  factory RandomPolicy.uniformAll({
    int? seed,
    int recentWindow = 1,
    int maxEntries = 128,
    String? label,
  }) {
    return RandomPolicy(
      scope: RandomScope.all(),
      strategy: RandomStrategy.uniform(),
      history: RandomHistoryPolicy(
        maxEntries: maxEntries,
        recentWindow: recentWindow,
      ),
      seed: seed,
      label: label ?? 'uniformAll',
    );
  }

  /// 只在指定播放列表内做等概率随机。
  factory RandomPolicy.uniformPlaylist(
    String playlistId, {
    int? seed,
    int recentWindow = 1,
    int maxEntries = 128,
    String? label,
  }) {
    return RandomPolicy(
      scope: RandomScope.playlist(playlistId),
      strategy: RandomStrategy.uniform(),
      history: RandomHistoryPolicy(
        maxEntries: maxEntries,
        recentWindow: recentWindow,
      ),
      seed: seed,
      label: label ?? 'uniformPlaylist',
    );
  }

  /// 只在指定索引区间内做等概率随机。
  factory RandomPolicy.uniformRange({
    required int startInclusive,
    required int endExclusive,
    int? seed,
    int recentWindow = 1,
    int maxEntries = 128,
    String? label,
  }) {
    return RandomPolicy(
      scope: RandomScope.range(
        startInclusive: startInclusive,
        endExclusive: endExclusive,
      ),
      strategy: RandomStrategy.uniform(),
      history: RandomHistoryPolicy(
        maxEntries: maxEntries,
        recentWindow: recentWindow,
      ),
      seed: seed,
      label: label ?? 'uniformRange',
    );
  }

  /// 只在指定歌曲 id 集合内做等概率随机。
  factory RandomPolicy.uniformTrackIds(
    Set<String> trackIds, {
    int? seed,
    int recentWindow = 1,
    int maxEntries = 128,
    String? label,
  }) {
    return RandomPolicy(
      scope: RandomScope.trackIds(trackIds),
      strategy: RandomStrategy.uniform(),
      history: RandomHistoryPolicy(
        maxEntries: maxEntries,
        recentWindow: recentWindow,
      ),
      seed: seed,
      label: label ?? 'uniformTrackIds',
    );
  }

  /// 通过过滤条件创建随机策略。
  factory RandomPolicy.filtered({
    required String id,
    required bool Function(
      AudioTrack track,
      int index,
      RandomSelectionContext context,
    )
    predicate,
    int? seed,
    int recentWindow = 1,
    int maxEntries = 128,
    String? label,
  }) {
    return RandomPolicy(
      scope: RandomScope.filtered(id: id, predicate: predicate),
      strategy: RandomStrategy.uniform(),
      history: RandomHistoryPolicy(
        maxEntries: maxEntries,
        recentWindow: recentWindow,
      ),
      seed: seed,
      label: label ?? 'filtered:$id',
    );
  }
}

class _AllRandomScope extends RandomScope {
  const _AllRandomScope();

  @override
  String get key => 'all';

  @override
  List<int> resolve(RandomSelectionContext context) {
    return List<int>.generate(context.tracks.length, (index) => index);
  }
}

class _PlaylistRandomScope extends RandomScope {
  const _PlaylistRandomScope(this.playlistId);

  final String playlistId;

  @override
  String get key => 'playlist:$playlistId';

  @override
  List<int> resolve(RandomSelectionContext context) {
    if (context.playlistId != playlistId) return const <int>[];
    return List<int>.generate(context.tracks.length, (index) => index);
  }
}

class _RangeRandomScope extends RandomScope {
  const _RangeRandomScope(this.startInclusive, this.endExclusive);

  final int startInclusive;
  final int endExclusive;

  @override
  String get key => 'range:$startInclusive:$endExclusive';

  @override
  List<int> resolve(RandomSelectionContext context) {
    if (context.tracks.isEmpty) return const <int>[];
    final start = startInclusive.clamp(0, context.tracks.length).toInt();
    final end = endExclusive.clamp(0, context.tracks.length).toInt();
    if (start >= end) return const <int>[];
    return List<int>.generate(end - start, (index) => start + index);
  }
}

class _TrackIdsRandomScope extends RandomScope {
  const _TrackIdsRandomScope(this.trackIds);

  final Set<String> trackIds;

  @override
  String get key => 'trackIds:${trackIds.length}';

  @override
  List<int> resolve(RandomSelectionContext context) {
    final candidates = <int>[];
    for (var i = 0; i < context.tracks.length; i++) {
      if (trackIds.contains(context.tracks[i].id)) {
        candidates.add(i);
      }
    }
    return candidates;
  }
}

class _PredicateRandomScope extends RandomScope {
  const _PredicateRandomScope(this.id, this.predicate);

  final String id;
  final bool Function(
    AudioTrack track,
    int index,
    RandomSelectionContext context,
  )
  predicate;

  @override
  String get key => 'filtered:$id';

  @override
  List<int> resolve(RandomSelectionContext context) {
    final candidates = <int>[];
    for (var i = 0; i < context.tracks.length; i++) {
      final track = context.tracks[i];
      if (predicate(track, i, context)) {
        candidates.add(i);
      }
    }
    return candidates;
  }
}

class _UniformRandomStrategy extends RandomStrategy {
  const _UniformRandomStrategy();

  @override
  String get key => 'uniform';

  @override
  int select(
    math.Random random,
    List<int> candidates,
    RandomSelectionContext context,
  ) {
    if (candidates.isEmpty) {
      throw StateError('No random candidates available.');
    }
    return candidates[random.nextInt(candidates.length)];
  }
}

class _WeightedRandomStrategy extends RandomStrategy {
  const _WeightedRandomStrategy(this.id, this.weightOf);

  final String id;
  final double Function(
    AudioTrack track,
    int index,
    RandomSelectionContext context,
  )
  weightOf;

  @override
  String get key => 'weighted:$id';

  @override
  int select(
    math.Random random,
    List<int> candidates,
    RandomSelectionContext context,
  ) {
    if (candidates.isEmpty) {
      throw StateError('No random candidates available.');
    }

    var totalWeight = 0.0;
    final weights = <double>[];
    for (final index in candidates) {
      final track = context.trackAt(index);
      final weight = track == null ? 0.0 : weightOf(track, index, context);
      final normalized = weight.isFinite && weight > 0.0 ? weight : 0.0;
      weights.add(normalized);
      totalWeight += normalized;
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
  }
}

class _CallbackRandomStrategy extends RandomStrategy {
  const _CallbackRandomStrategy(this.id, this.selectCallback);

  final String id;
  final int Function(
    math.Random random,
    List<int> candidates,
    RandomSelectionContext context,
  )
  selectCallback;

  @override
  String get key => 'callback:$id';

  @override
  int select(
    math.Random random,
    List<int> candidates,
    RandomSelectionContext context,
  ) {
    if (candidates.isEmpty) {
      throw StateError('No random candidates available.');
    }
    final selected = selectCallback(random, candidates, context);
    if (selected < 0 || selected >= context.tracks.length) {
      throw StateError('Custom random strategy returned an invalid index.');
    }
    if (!candidates.contains(selected)) {
      throw StateError(
        'Custom random strategy returned a non-candidate index.',
      );
    }
    return selected;
  }
}
