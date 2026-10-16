import 'package:audio_core/src/player_models.dart';
import 'package:audio_core/src/playlist_controller.dart';
import 'package:audio_core/src/playlist_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// 记录每次通知时的「当前曲目」，用来观察中间态。
class _RecordingParent implements AudioVisualizerParent {
  final List<String?> snapshots = <String?>[];
  int loadCount = 0;
  int clearCount = 0;

  PlaylistController? controller;

  @override
  void notifyListeners() {
    snapshots.add(controller?.currentTrack?.id);
  }

  @override
  Future<void> loadTrack({
    required bool autoPlay,
    Duration? position,
    PlaybackReason reason = PlaybackReason.playlistChanged,
    FadeSettings? fadeSetting,
  }) async {
    loadCount++;
  }

  @override
  Future<void> clearPlayback() async {
    clearCount++;
  }

  @override
  Future<bool> canPlayTrack(AudioTrack track) async => true;

  @override
  Future<String> resolvePlayableUri(String rawUri) async => rawUri;

  @override
  Future<bool> handlePlayRequested() async => false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

AudioTrack _track(String id) => AudioTrack(id: id, uri: 'file:///$id');

void main() {
  late _RecordingParent parent;
  late PlaylistController controller;

  setUp(() {
    parent = _RecordingParent();
    controller = PlaylistController(parent: parent);
    parent.controller = controller;
  });

  /// 起始状态：当前播放 a1（列表 [a1, a2]）。
  Future<void> seed() async {
    await controller.replaceActiveTracksAndSelect(
      controller.activePlaylistId!,
      <AudioTrack>[_track('a1'), _track('a2')],
    );
    parent.snapshots.clear();
    parent.loadCount = 0;
    parent.clearCount = 0;
  }

  test('两步写法（updatePlaylistTracks + playByIndex）会暴露「当前曲目为空」的中间态', () async {
    await seed();

    final id = controller.activePlaylistId!;
    await controller.updatePlaylistTracks(
      id,
      <AudioTrack>[_track('b1'), _track('b2')],
      reconcile: false,
    );
    await controller.playByIndex(1);

    // a1 不在新列表里 -> _currentIndex 被置 null 并通知一次。
    expect(parent.snapshots, contains(null));
    expect(controller.currentTrack?.id, 'b2');
  });

  test('replaceActiveTracksAndSelect 全程不暴露「当前曲目为空」的中间态', () async {
    await seed();

    await controller.replaceActiveTracksAndSelect(
      controller.activePlaylistId!,
      <AudioTrack>[_track('b1'), _track('b2')],
      startIndex: 1,
    );

    expect(parent.snapshots, isNot(contains(null)));
    expect(parent.snapshots, contains('b2'));
    expect(parent.clearCount, 0);
    expect(parent.loadCount, 1);
    expect(controller.currentTrack?.id, 'b2');
    expect(controller.currentIndex, 1);
    expect(controller.items.length, 2);
  });

  test('新列表仍包含当前曲目时，replaceActiveTracksAndSelect 落到对应下标', () async {
    await seed();

    await controller.replaceActiveTracksAndSelect(
      controller.activePlaylistId!,
      <AudioTrack>[_track('c1'), _track('a1')],
      startIndex: 1,
    );

    expect(parent.snapshots, isNot(contains(null)));
    expect(controller.currentTrack?.id, 'a1');
    expect(controller.currentIndex, 1);
  });

  test('空列表退化为旧语义（不加载、不崩溃）', () async {
    await seed();

    await controller.replaceActiveTracksAndSelect(
      controller.activePlaylistId!,
      const <AudioTrack>[],
    );

    expect(controller.currentTrack, isNull);
    expect(parent.loadCount, 0);
  });
}
