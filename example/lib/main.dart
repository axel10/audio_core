import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:audio_core/audio_core.dart';
import 'package:file_picker/file_picker.dart';
import 'equalizer_panel.dart';
import 'fade_demo_tab.dart';
import 'widgets.dart';
import 'random_lab_tab.dart';
import 'audio_handler.dart';
import 'android_media_library_picker.dart';
import 'package:audio_service/audio_service.dart';

late AudioCoreHandler audioHandler;

void main() async {
  // 确保 Flutter 绑定已初始化
  WidgetsFlutterBinding.ensureInitialized();

  final controller = AudioCoreController(
    fftSize: 1024,
    analysisFrequencyHz: 30,
    fadeSettings: const FadeSettings(
      fadeOnSwitch: true,
      fadeOnPauseResume: true,
      duration: Duration(milliseconds: 500),
      mode: FadeMode.crossfade,
    ),
    visualOptions: const VisualizerOptimizationOptions(
      smoothingCoefficient: 0.35,
      gravityCoefficient: 10,
      logarithmicScale: 4,
      normalizationFloorDb: -85,
      aggregationMode: FftAggregationMode.peak,
      frequencyGroups: 64,
      targetFrameRate: 60,
      groupContrastExponent: 1.6,
      overallMultiplier: 1.2,
    ),
  );

  audioHandler = await AudioService.init(
    builder: () => AudioCoreHandler(controller),
    config: const AudioServiceConfig(
      androidNotificationChannelId:
          'com.flutter_rust_bridge.audio_core.channel.audio',
      androidNotificationChannelName: 'Audio Playback',
      androidNotificationOngoing: true,
    ),
  );

  runApp(MyApp(controller: controller));
}

class MyApp extends StatelessWidget {
  final AudioCoreController controller;
  const MyApp({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Audio Visualizer Player Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: VisualizerDemoPage(controller: controller),
    );
  }
}

class VisualizerDemoPage extends StatefulWidget {
  final AudioCoreController controller;
  const VisualizerDemoPage({super.key, required this.controller});

  @override
  State<VisualizerDemoPage> createState() => _VisualizerDemoPageState();
}

class _VisualizerDemoPageState extends State<VisualizerDemoPage> {
  late final AudioCoreController _controller;
  StreamSubscription<FftFrame>? _subSmooth;
  StreamSubscription<FftFrame>? _subResponsive;
  List<double> _bandsSmooth = const [];
  List<double> _bandsResponsive = const [];
  AudioLibraryFolder? _mediaLibraryRoot;
  bool _mediaLibraryLoading = false;
  String? _mediaLibraryError;

  final GlobalKey<RandomLabTabState> _randomLabKey =
      GlobalKey<RandomLabTabState>();

  List<double> _waveform = [];
  final int _waveformChunks = 80;
  int _waveformStride = 2;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller;
    // _controller.initialize(); // Already initialized or will be initialized via handler logic if needed
    // However, the original code had _controller.initialize() here.
    // Since it's a plugin demo, let's keep it but ensure it's idempotent.
    if (!_controller.isInitialized) {
      _controller.initialize();
    }

    // 创建平滑风格输出流 - 高平滑、低响应速度
    final smoothOutput = _controller.visualizer.createOutput(
      const VisualizerOutputConfig(
        id: 'smooth',
        label: 'Smooth',
        options: VisualizerOptimizationOptions(
          smoothingCoefficient: 0.75,
          gravityCoefficient: 0.5,
          logarithmicScale: 2.5,
          normalizationFloorDb: -70,
          aggregationMode: FftAggregationMode.peak,
          frequencyGroups: 32,
          targetFrameRate: 60,
          groupContrastExponent: 1.5,
        ),
      ),
    );

    // 创建响应风格输出流 - 低平滑、快响应速度
    final responsiveOutput = _controller.visualizer.createOutput(
      const VisualizerOutputConfig(
        id: 'responsive',
        label: 'Responsive',
        options: VisualizerOptimizationOptions(
          smoothingCoefficient: 0.2,
          gravityCoefficient: 3.0,
          logarithmicScale: 1.5,
          normalizationFloorDb: -85,
          aggregationMode: FftAggregationMode.peak,
          frequencyGroups: 64,
          targetFrameRate: 60,
          groupContrastExponent: 1.2,
        ),
      ),
    );

    // 订阅平滑风格流
    _subSmooth = smoothOutput.fftStream.listen((frame) {
      if (!mounted) return;
      setState(() {
        _bandsSmooth = frame.values;
      });
    });

    // 订阅响应风格流
    _subResponsive = responsiveOutput.fftStream.listen((frame) {
      if (!mounted) return;
      setState(() {
        _bandsResponsive = frame.values;
      });
    });

    _bootstrapAudioLibrary();
  }

  Future<void> _bootstrapAudioLibrary() async {
    if (!Platform.isAndroid) return;

    // 启动时先拿权限，然后从 Android 侧读取系统媒体库。
    // 这里拿到的是平面列表，后面会在 Dart 侧构建成文件夹树。
    setState(() {
      _mediaLibraryLoading = true;
      _mediaLibraryError = null;
    });

    try {
      final scanResult = await _controller.scanAndroidMediaLibrary();
      if (!mounted) return;
      setState(() {
        _mediaLibraryLoading = false;
        _mediaLibraryError = scanResult.isSuccessful
            ? null
            : scanResult.errorMessage ?? scanResult.errorCode;
        _mediaLibraryRoot = scanResult.permissionGranted
            ? buildAudioLibraryTree(scanResult.entries)
            : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _mediaLibraryLoading = false;
        _mediaLibraryError = e.toString();
      });
    }
  }

  Future<void> _pickAudio({FadeSettings? fadeSetting}) async {
    debugPrint('Select Audio clicked');
    if (!_controller.isInitialized) {
      debugPrint('Controller not initialized, initializing now...');
      await _controller.initialize();
    }

    if (Platform.isAndroid) {
      final root = _mediaLibraryRoot;
      if (root == null) {
        await _bootstrapAudioLibrary();
      }

      // Android 上不再走 file_picker，而是弹出我们自己写的媒体库面板。
      final refreshedRoot = _mediaLibraryRoot;
      if (refreshedRoot == null) {
        if (!mounted) return;
        _showMediaLibrarySnack(
          _mediaLibraryError ?? 'Audio library is not ready yet.',
        );
        return;
      }

      final selected = await _openAndroidMediaLibraryPicker(refreshedRoot);
      if (selected == null) return;

      await _registerImportedTracks(
        [selected.toAudioTrack()],
        addToActivePlaylist: true,
        fadeSetting: fadeSetting,
      );
      return;
    }

    final result = await FilePicker.platform.pickFiles(
      type: FileType.audio,
      allowMultiple: true,
    );
    debugPrint('File picker returned: ${result?.files.length ?? 0} files');
    if (result == null || result.files.isEmpty) {
      return;
    }

    final tracks = result.files
        .map((file) {
          final path = file.path;
          if (path == null || path.isEmpty) {
            return null;
          }
          return _makeTrack(id: path, title: file.name, uri: path);
        })
        .whereType<AudioTrack>()
        .toList();

    if (tracks.isEmpty) {
      return;
    }

    await _registerImportedTracks(
      tracks,
      addToActivePlaylist: true,
      fadeSetting: fadeSetting,
    );
  }

  Future<AndroidMediaLibraryEntry?> _openAndroidMediaLibraryPicker(
    AudioLibraryFolder root,
  ) {
    return showAndroidMediaLibraryPicker(context, root: root);
  }

  void _showMediaLibrarySnack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  AudioTrack _makeTrack({
    required String id,
    required String title,
    required String uri,
  }) {
    return AudioTrack(
      id: id,
      title: title,
      uri: uri,
      metadata: <String, Object?>{'isLike': false, 'playCount': 0},
    );
  }

  Future<void> _registerImportedTracks(
    List<AudioTrack> tracks, {
    bool addToActivePlaylist = false,
    bool addToQueue = false,
    String? targetPlaylistId,
    FadeSettings? fadeSetting,
  }) async {
    if (tracks.isEmpty) return;

    // 同步到 Random Lab 的 Library
    _randomLabKey.currentState?.addTracksToLibrary(tracks);

    if (addToActivePlaylist) {
      await _controller.playlist.addTracks(tracks, fadeSetting: fadeSetting);
      if (!_controller.player.isPlaying &&
          _controller.player.currentPath != null) {
        await _controller.player.play(fadeSetting: fadeSetting);
      }
    }

    if (addToQueue) {
      await _controller.playlist.ensureQueuePlaylist();
      await _controller.playlist.addTracksToPlaylist(
        _controller.playlist.queuePlaylistId,
        tracks,
        fadeSetting: fadeSetting,
      );
    }

    if (targetPlaylistId != null) {
      await _controller.playlist.addTracksToPlaylist(
        targetPlaylistId,
        tracks,
        fadeSetting: fadeSetting,
      );
    }
  }

  Future<void> _loadWaveform() async {
    final waveform = await _controller.getWaveform(
      expectedChunks: _waveformChunks,
      sampleStride: _waveformStride,
    );
    if (!mounted) return;
    debugPrint(waveform.toString());
    setState(() {
      _waveform = waveform;
    });
  }

  @override
  void dispose() {
    _subSmooth?.cancel();
    _subResponsive?.cancel();
    // 采用单例模式后，不应在此处直接销毁全局控制器，否则页面重建会无法清理定时器
    // _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return DefaultTabController(
          length: 4,
          child: Scaffold(
            appBar: AppBar(
              title: const Text('Audio Visualizer Player Plugin Demo'),
              backgroundColor: Theme.of(context).colorScheme.inversePrimary,
              bottom: const TabBar(
                tabs: [
                  Tab(icon: Icon(Icons.music_note), text: 'Player'),
                  Tab(icon: Icon(Icons.tune), text: 'Fade Demo'),
                  Tab(icon: Icon(Icons.shuffle), text: 'Random Lab'),
                  Tab(icon: Icon(Icons.equalizer), text: 'Equalizer'),
                ],
              ),
            ),
            body: TabBarView(
              children: [
                // 第一页: 播放器主界面
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      _buildPlayerControls(),
                      if (Platform.isAndroid)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              _mediaLibraryLoading
                                  ? 'Scanning system media library...'
                                  : _mediaLibraryError == null
                                  ? 'System media library ready'
                                  : 'Library scan failed: $_mediaLibraryError',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        ),
                      const SizedBox(height: 12),
                      _buildFileAndWaveform(),
                      const SizedBox(height: 16),
                      // 双频谱可视化展示
                      Expanded(
                        child: AudioDropRegion(
                          controller: _controller,
                          onTracksAccepted: (tracks) => _registerImportedTracks(
                            tracks,
                            addToActivePlaylist: true,
                          ),
                          child: _buildSpectrumVisualizers(),
                        ),
                      ),
                    ],
                  ),
                ),
                // 第二页: 淡入淡出控制演示
                FadeDemoTab(
                  controller: _controller,
                  onLoadMusicPressed: (fadeSetting) =>
                      _pickAudio(fadeSetting: fadeSetting),
                  onLoadMusicWithFadePressed: (fadeSetting) =>
                      _pickAudio(fadeSetting: fadeSetting),
                ),
                // 第二页: 随机播放实验台
                RandomLabTab(key: _randomLabKey, controller: _controller),
                // 第四页: 均衡器界面
                SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: EqualizerPanel(controller: _controller),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _format(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  Widget _buildPlayerControls() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          ElevatedButton(
            onPressed: _controller.isSupported ? _pickAudio : null,
            child: const Text('Select Audio'),
          ),
          const SizedBox(width: 12),
          ElevatedButton(
            onPressed: _controller.player.currentPath != null
                ? () => _controller.playlist.playPrevious()
                : null,
            child: const Icon(Icons.skip_previous),
          ),
          const SizedBox(width: 12),
          ElevatedButton(
            onPressed: _controller.player.currentPath != null
                ? () => _controller.player.togglePlayPause()
                : null,
            child: Icon(
              _controller.player.isPlaying ? Icons.pause : Icons.play_arrow,
            ),
          ),
          const SizedBox(width: 12),
          ElevatedButton(
            onPressed: _controller.player.currentPath != null
                ? () => _controller.playlist.playNext()
                : null,
            child: const Icon(Icons.skip_next),
          ),
          const SizedBox(width: 12),
          DropdownButton<PlaylistMode>(
            value: _controller.playlist.mode,
            items: PlaylistMode.values.map((mode) {
              return DropdownMenuItem(
                value: mode,
                child: Text(mode.name.toUpperCase()),
              );
            }).toList(),
            onChanged: (mode) {
              if (mode != null) {
                _controller.playlist.setMode(mode);
              }
            },
          ),
          const SizedBox(width: 12),

          ElevatedButton.icon(
            onPressed: _controller.player.currentPath != null
                ? () async {
                    final track = _controller.playlist.currentTrack;
                    if (track == null) return;

                    final result = await FilePicker.platform.pickFiles(
                      type: FileType.image,
                      allowMultiple: false,
                    );

                    if (result == null || result.files.isEmpty) {
                      return;
                    }

                    final path = result.files.single.path;
                    if (path == null) return;

                    final bytes = await File(path).readAsBytes();
                    final ext = result.files.single.extension?.toLowerCase();
                    final mimeType = (ext == 'png')
                        ? 'image/png'
                        : 'image/jpeg';

                    final success = await _controller.updateMetadata(
                      track,
                      metadata: AndroidTrackMetadataUpdate(
                        title: track.title,
                        artist: track.artist,
                        album: track.album,
                        pictures: [
                          AndroidTrackPicture(bytes: bytes, mimeType: mimeType),
                        ],
                      ),
                    );

                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            success
                                ? 'Metadata updated successfully!'
                                : 'Failed to update metadata.',
                          ),
                          backgroundColor: success ? Colors.green : Colors.red,
                        ),
                      );
                    }
                  }
                : null,
            icon: const Icon(Icons.edit_note),
            label: const Text('Change Cover'),
          ),
        ],
      ),
    );
  }

  Widget _buildFileAndWaveform() {
    return Column(
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            _controller.player.currentPath ?? 'No file selected',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (_controller.player.lastFingerprint != null)
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.blue.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: Colors.blue.withValues(alpha: 0.3)),
              ),
              child: SelectableText(
                'Fingerprint: ${_controller.player.lastFingerprint!.length > 20 ? '${_controller.player.lastFingerprint!.substring(0, 20)}...' : _controller.player.lastFingerprint}',
                style: const TextStyle(
                  fontSize: 10,
                  fontFamily: 'monospace',
                  color: Colors.blue,
                ),
              ),
            ),
          ),
        if (_controller.player.currentPath != null)
          ElevatedButton(
            onPressed: () => _loadWaveform(),
            child: const Text('Extract Full Waveform (Fast)'),
          ),
        if (_controller.player.currentPath != null)
          Row(
            children: [
              const Text('Waveform Stride'),
              const SizedBox(width: 12),
              Expanded(
                child: Slider(
                  min: 1,
                  max: 32,
                  divisions: 31,
                  value: _waveformStride.toDouble(),
                  label: '$_waveformStride',
                  onChanged: (value) {
                    setState(() {
                      _waveformStride = value.round().clamp(1, 32);
                    });
                  },
                ),
              ),
              SizedBox(
                width: 36,
                child: Text('$_waveformStride', textAlign: TextAlign.right),
              ),
            ],
          ),
        if (_controller.playlist.items.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Playlist: ${(_controller.playlist.currentIndex ?? -1) + 1} / ${_controller.playlist.items.length}',
            ),
          ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            '${_format(_controller.player.position)} / ${_format(_controller.player.duration)}',
          ),
        ),
        Slider(
          value: _controller.player.duration.inMilliseconds > 0
              ? _controller.player.position.inMilliseconds.toDouble().clamp(
                  0,
                  _controller.player.duration.inMilliseconds.toDouble(),
                )
              : 0.0,
          max: _controller.player.duration.inMilliseconds.toDouble() > 0
              ? _controller.player.duration.inMilliseconds.toDouble()
              : 1.0,
          onChanged: (value) {
            _controller.player.seek(Duration(milliseconds: value.toInt()));
          },
        ),
        if (_controller.player.error != null) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              _controller.player.error!,
              style: const TextStyle(color: Colors.red),
            ),
          ),
        ],
        const SizedBox(height: 16),
        SizedBox(
          height: 60,
          width: double.infinity,
          child: CustomPaint(
            painter: WaveformPainter(
              _waveform,
              _controller.player.duration.inMilliseconds > 0
                  ? _controller.player.position.inMilliseconds /
                        _controller.player.duration.inMilliseconds
                  : 0.0,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSpectrumVisualizers() {
    return Row(
      children: [
        // 平滑风格可视化
        Expanded(
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.purple.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  'Smooth Style',
                  style: TextStyle(
                    color: Colors.purple,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: CustomPaint(
                    painter: DemoSpectrumPainter(
                      _bandsSmooth,
                      color: Colors.purple,
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        // 响应风格可视化
        Expanded(
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  'Responsive Style',
                  style: TextStyle(
                    color: Colors.orange,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: CustomPaint(
                    painter: DemoSpectrumPainter(
                      _bandsResponsive,
                      color: Colors.orange,
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
