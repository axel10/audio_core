import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:audio_core/audio_core.dart';
import 'package:file_picker/file_picker.dart';
import 'equalizer_panel.dart';
import 'fade_demo_tab.dart';
import 'metadata_tab.dart';
import 'mesh_demo_tab.dart';
import 'widgets.dart';
import 'random_lab_tab.dart';
import 'transcode_tab.dart';
import 'audio_handler.dart';
import 'android_media_library_picker.dart';
import 'apple_directory_tab.dart';
import 'package:audio_service/audio_service.dart';

late AudioCoreHandler audioHandler;

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
  'mp4',
  'mid',
  'midi',
  'mp3',
  'ogg',
  'opus',
  'wav',
  'webm',
];

void main() {
  runZonedGuarded(
    () async {
      // 确保 Flutter 绑定已初始化
      WidgetsFlutterBinding.ensureInitialized();
      await AppLog.ensureInitialized();
      AppLog.install();
      AppLog.installFlutterErrorHandlers();

      final controller = AudioCoreController(
        fftSize: 1024,
        analysisFrequencyHz: 60,
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
          frequencyGroups: 32,
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
    },
    (error, stack) {
      AppLog.e(
        'Uncaught Flutter zone error',
        tag: 'Flutter',
        error: error,
        stackTrace: stack,
      );
    },
  );
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
  static const double _rawSpectrumMinHeight = 220;
  static const double _spectrumVisualizersMinHeight = 320;

  late final AudioCoreController _controller;
  final AudioConverter _audioConverter = AudioConverter();
  AudioLibraryFolder? _mediaLibraryRoot;
  bool _mediaLibraryLoading = false;
  String? _mediaLibraryError;
  String? _playbackDecodeEngine;
  String? _converterEngine;
  bool _showCurrentPlayingDetails = false;

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
    _controller.visualizer.createOutput(
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
    _controller.visualizer.createOutput(
      const VisualizerOutputConfig(
        id: 'responsive',
        label: 'Responsive',
        options: VisualizerOptimizationOptions(
          smoothingCoefficient: 0.2,
          gravityCoefficient: 3.0,
          logarithmicScale: 1.5,
          normalizationFloorDb: -85,
          aggregationMode: FftAggregationMode.peak,
          frequencyGroups: 32,
          targetFrameRate: 60,
          groupContrastExponent: 1.2,
        ),
      ),
    );

    _bootstrapAudioLibrary();
    _refreshEngineInfo();
  }

  Future<void> _refreshEngineInfo() async {
    try {
      final playbackEngine = await _controller.engine.getDecodeEngine();
      final converterCapabilities = await _audioConverter.getCapabilities();
      if (!mounted) return;
      setState(() {
        _playbackDecodeEngine = playbackEngine;
        _converterEngine = converterCapabilities.engine;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _playbackDecodeEngine ??= 'unknown';
        _converterEngine ??= 'unavailable';
      });
      debugPrint('[AudioCore][Example] Failed to refresh engine info: $e');
    }
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
    debugPrint('[AudioCore][Example] Select Audio clicked');
    if (!_controller.isInitialized) {
      debugPrint(
        '[AudioCore][Example] Controller not initialized, initializing now...',
      );
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

      await _handleImportedTracks([
        selected.toAudioTrack(),
      ], fadeSetting: fadeSetting);
      return;
    }

    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: _audioFileExtensions,
      allowMultiple: true,
    );
    debugPrint(
      '[AudioCore][Example] File picker returned: ${result?.files.length ?? 0} files',
    );
    if (result == null || result.files.isEmpty) {
      return;
    }

    final paths = result.files
        .map((file) {
          final path = file.path;
          if (path == null || path.isEmpty) {
            return null;
          }
          return path;
        })
        .whereType<String>()
        .toList();

    if (paths.isEmpty) {
      return;
    }

    await _handleImportedPaths(paths, fadeSetting: fadeSetting);
  }

  Future<void> _pickAudioWithFilePicker({FadeSettings? fadeSetting}) async {
    debugPrint('[AudioCore][Example] File picker audio clicked');
    if (!_controller.isInitialized) {
      debugPrint(
        '[AudioCore][Example] Controller not initialized, initializing now...',
      );
      await _controller.initialize();
    }

    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: _audioFileExtensions,
      allowMultiple: false,
    );
    debugPrint(
      '[AudioCore][Example] File picker returned: ${result?.files.length ?? 0} files',
    );
    if (result == null || result.files.isEmpty) {
      return;
    }

    final path = result.files.first.path;
    if (path == null || path.isEmpty) {
      return;
    }

    await _handleImportedPaths([path], fadeSetting: fadeSetting);
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

  Future<void> _handleImportedPaths(
    List<String> paths, {
    FadeSettings? fadeSetting,
  }) async {
    if (paths.isEmpty) return;

    final tracks = _controller.resolveAudioTracks(paths);

    // 同步到 Random Lab 的 Library
    _randomLabKey.currentState?.addTracksToLibrary(tracks);

    await _controller.playPaths(
      paths,
      autoPlayFirst: true,
      fadeSetting: fadeSetting,
    );
    await _refreshEngineInfo();
  }

  Future<void> _handleImportedTracks(
    List<AudioTrack> tracks, {
    FadeSettings? fadeSetting,
  }) async {
    if (tracks.isEmpty) return;

    _randomLabKey.currentState?.addTracksToLibrary(tracks);

    // Keep the original AudioTrack objects when we already have them so
    // platform-specific metadata such as Android's mediaUri survives.
    if (tracks.length == 1) {
      await _controller.playTrack(tracks.first, fadeSetting: fadeSetting);
      await _refreshEngineInfo();
      return;
    }

    await _controller.playPaths(
      tracks.map((track) => track.uri).toList(),
      autoPlayFirst: true,
      fadeSetting: fadeSetting,
    );
    await _refreshEngineInfo();
  }

  Future<void> _loadWaveform() async {
    final waveform = await _controller.getWaveform(
      expectedChunks: _waveformChunks,
      sampleStride: _waveformStride,
    );
    if (!mounted) return;
    debugPrint('[AudioCore][Example] waveform=$waveform');
    setState(() {
      _waveform = waveform;
    });
  }

  @override
  void dispose() {
    // 采用单例模式后，不应在此处直接销毁全局控制器，否则页面重建会无法清理定时器
    // _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 8,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Audio Visualizer Player Plugin Demo'),
          backgroundColor: Theme.of(context).colorScheme.inversePrimary,
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.music_note), text: 'Player'),
              Tab(icon: Icon(Icons.info_outline), text: 'Metadata'),
              Tab(icon: Icon(Icons.tune), text: 'Fade Demo'),
              Tab(icon: Icon(Icons.blur_on), text: 'Mesh'),
              Tab(icon: Icon(Icons.shuffle), text: 'Random Lab'),
              Tab(icon: Icon(Icons.folder_open), text: 'Apple Dir'),
              Tab(icon: Icon(Icons.transform), text: 'Transcode'),
              Tab(icon: Icon(Icons.equalizer), text: 'Equalizer'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            // 第一页: 播放器主界面
            SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AnimatedBuilder(
                    animation: _controller,
                    builder: (context, _) => _buildPlayerControls(),
                  ),
                   const SizedBox(height: 8),
                  _buildEngineInfo(context),
                  const SizedBox(height: 8),
                  _buildAudioDetailsControls(context),
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
                  AnimatedBuilder(
                    animation: _controller,
                    builder: (context, _) => _buildFileAndWaveform(),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    height: _rawSpectrumMinHeight,
                    child: _buildRawSpectrumPanel(),
                  ),
                  const SizedBox(height: 16),
                  // 双频谱可视化展示
                  SizedBox(
                    height: _spectrumVisualizersMinHeight,
                    child: AudioDropRegion(
                      controller: _controller,
                      onPathsAccepted: (paths) => _handleImportedPaths(paths),
                      child: _buildSpectrumVisualizers(),
                    ),
                  ),
                ],
              ),
            ),
            // 第二页: 当前曲目信息 / 封面编辑
            MetadataTab(controller: _controller),
            // 第三页: 淡入淡出控制演示
            FadeDemoTab(
              controller: _controller,
              onLoadMusicPressed: (fadeSetting) =>
                  _pickAudio(fadeSetting: fadeSetting),
              onLoadMusicWithFadePressed: (fadeSetting) =>
                  _pickAudio(fadeSetting: fadeSetting),
            ),
            // 第四页: 封面驱动的 mesh 动画背景
            MeshDemoTab(controller: _controller),
            // 第五页: 随机播放实验台
            RandomLabTab(key: _randomLabKey, controller: _controller),
            // 第六页: 苹果目录扫描页
            AppleDirectoryTab(controller: _controller),
            // 第七页: 转码演示
            TranscodeTab(audioConverter: _audioConverter),
            // 第八页: 均衡器界面
            SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: EqualizerPanel(controller: _controller),
            ),
          ],
        ),
      ),
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
            onPressed: _controller.isSupported
                ? _pickAudioWithFilePicker
                : null,
            child: const Text('File Picker'),
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
        ],
      ),
    );
  }

  Widget _buildEngineInfo(BuildContext context) {
    final playbackEngine = _playbackDecodeEngine ?? 'loading...';
    final converterEngine = _converterEngine ?? 'loading...';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: DefaultTextStyle(
        style: Theme.of(context).textTheme.bodyMedium!,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Playback decode engine: $playbackEngine'),
            const SizedBox(height: 4),
            Text('audio_converter engine: $converterEngine'),
          ],
        ),
      ),
    );
  }

  Widget _buildAudioDetailsControls(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            ElevatedButton.icon(
              onPressed: _handleGetAudioDetails,
              icon: const Icon(Icons.info),
              label: Text(_showCurrentPlayingDetails ? 'Get Current Playing Details' : 'Select File Details'),
            ),
            const SizedBox(width: 12),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Checkbox(
                  value: _showCurrentPlayingDetails,
                  onChanged: (val) {
                    setState(() {
                      _showCurrentPlayingDetails = val ?? false;
                    });
                  },
                ),
                const Text('Current Playing'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleGetAudioDetails() async {
    String? path;
    if (_showCurrentPlayingDetails) {
      path = _controller.player.currentPath;
      if (path == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No song is currently playing.')),
        );
        return;
      }
    } else {
      // Pick a file
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: _audioFileExtensions,
        allowMultiple: false,
      );
      if (result == null || result.files.isEmpty) {
        return;
      }
      path = result.files.first.path;
      if (path == null || path.isEmpty) {
        return;
      }
    }

    try {
      final details = await _controller.engine.getAudioDetails(path: path);
      if (!mounted) return;

      await showDialog<void>(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: const Text('Audio Details'),
            content: SingleChildScrollView(
              child: ListBody(
                children: [
                  Text('File Path: $path'),
                  const SizedBox(height: 8),
                  Text('Format: ${details.formatName}'),
                  Text('Codec: ${details.codecName}'),
                  Text('Duration: ${details.duration.inMinutes}:${(details.duration.inSeconds % 60).toString().padLeft(2, '0')} (${details.duration.inMilliseconds} ms)'),
                  Text('Bitrate: ${(details.bitrate / 1000).toStringAsFixed(1)} kbps'),
                  Text('Sample Rate: ${details.sampleRate} Hz'),
                  Text('Channels: ${details.channels}'),
                  Text('Bit Depth: ${details.bitDepth != null ? "${details.bitDepth} bit" : "N/A"}'),
                  Text('Bitrate Mode: ${details.bitrateMode}'),
                  Text('File Size: ${(details.fileSize / 1024 / 1024).toStringAsFixed(2)} MB (${details.fileSize} bytes)'),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('OK'),
              ),
            ],
          );
        },
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to retrieve audio details: $e')),
      );
    }
  }

  Widget _buildFileAndWaveform() {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                _controller.player.currentPath ?? 'No file selected',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (_controller.player.currentPath != null)
              TextButton.icon(
                onPressed: _showCurrentPathDetails,
                icon: const Icon(Icons.info_outline, size: 18),
                label: const Text('Path Details'),
              ),
          ],
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
        Row(
          children: [
            const Icon(Icons.volume_down, size: 20),
            Expanded(
              child: Slider(
                value: _controller.player.volume,
                onChanged: (v) => _controller.player.setVolume(v),
              ),
            ),
            const Icon(Icons.volume_up, size: 20),
            const SizedBox(width: 8),
            SizedBox(
              width: 40,
              child: Text(
                '${(_controller.player.volume * 100).toInt()}%',
                textAlign: TextAlign.right,
              ),
            ),
          ],
        ),
        Row(
          children: [
            const Icon(Icons.speed, size: 20),
            Expanded(
              child: Slider(
                min: 0.5,
                max: 5.0,
                divisions: 90,
                value: _controller.player.playbackSpeed,
                label: '${_controller.player.playbackSpeed.toStringAsFixed(2)}x',
                onChanged: (v) => _controller.player.setPlaybackSpeed(v),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 45,
              child: Text(
                '${_controller.player.playbackSpeed.toStringAsFixed(2)}x',
                textAlign: TextAlign.right,
              ),
            ),
          ],
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (final speed in [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0, 5.0])
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: ChoiceChip(
                    label: Text('${speed}x'),
                    selected: (_controller.player.playbackSpeed - speed).abs() < 0.01,
                    onSelected: (selected) {
                      if (selected) {
                        _controller.player.setPlaybackSpeed(speed);
                      }
                    },
                  ),
                ),
            ],
          ),
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

  void _showCurrentPathDetails() {
    final currentTrack = _controller.playlist.currentTrack;
    final currentPath = _controller.player.currentPath;
    final metadata = currentTrack?.metadata ?? const <String, Object?>{};

    final details = <String>[
      'Platform: ${Platform.isAndroid ? 'Android' : Platform.operatingSystem}',
      'player.currentPath: ${currentPath ?? '(null)'}',
      'playlist.currentTrack.id: ${currentTrack?.id ?? '(null)'}',
      'playlist.currentTrack.uri: ${currentTrack?.uri ?? '(null)'}',
      'playlist.currentTrack.title: ${currentTrack?.title ?? '(null)'}',
      'playlist.currentTrack.artist: ${currentTrack?.artist ?? '(null)'}',
      'playlist.currentTrack.album: ${currentTrack?.album ?? '(null)'}',
      'metadata.filePath: ${_stringMetadata(metadata, 'filePath')}',
      'metadata.mediaUri: ${_stringMetadata(metadata, 'mediaUri')}',
      'metadata.selectedUri: ${_stringMetadata(metadata, 'selectedUri')}',
      'metadata.mediaUriLookup: ${_stringMetadata(metadata, 'mediaUriLookup')}',
      'metadata.displayName: ${_stringMetadata(metadata, 'displayName')}',
      'metadata.bucketDisplayName: ${_stringMetadata(metadata, 'bucketDisplayName')}',
      'metadata.mimeType: ${_stringMetadata(metadata, 'mimeType')}',
      'metadata.folderPath: ${_stringMetadata(metadata, 'folderPath')}',
    ].join('\n');

    showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Current Path Details'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: SingleChildScrollView(
              child: SelectableText(
                details,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  String _stringMetadata(Map<String, Object?> metadata, String key) {
    final value = metadata[key];
    if (value == null) return '(null)';
    final text = value.toString().trim();
    return text.isEmpty ? '(empty)' : text;
  }

  Widget _buildSpectrumVisualizers() {
    return Row(
      children: [
        // 平滑风格可视化
        Expanded(
          child: _buildStreamSpectrumPanel(
            title: 'Smooth Style',
            titleColor: Colors.purple,
            fillColor: Colors.purple,
            stream: _controller.visualizer.getOutput('smooth')!.fftStream,
          ),
        ),
        const SizedBox(width: 12),
        // 响应风格可视化
        Expanded(
          child: _buildStreamSpectrumPanel(
            title: 'Responsive Style',
            titleColor: Colors.orange,
            fillColor: Colors.orange,
            stream: _controller.visualizer.getOutput('responsive')!.fftStream,
          ),
        ),
      ],
    );
  }

  Widget _buildStreamSpectrumPanel({
    required String title,
    required Color titleColor,
    required Color fillColor,
    required Stream<FftFrame> stream,
  }) {
    return StreamBuilder<FftFrame>(
      stream: stream,
      builder: (context, snapshot) {
        final bands = snapshot.data?.values ?? const <double>[];
        return Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: titleColor.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                title,
                style: TextStyle(
                  color: titleColor,
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
                  painter: DemoSpectrumPainter(bands, color: fillColor),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildRawSpectrumPanel() {
    return StreamBuilder<FftFrame>(
      stream: _controller.visualizer.rawStream,
      builder: (context, snapshot) {
        final bands = snapshot.data?.values ?? const <double>[];
        // print('[AudioCore][Example] Raw FFT frame received with ${bands.toString()} bands');
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.cyan.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text(
                'Raw FFT',
                style: TextStyle(
                  color: Colors.cyanAccent,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final contentWidth = bands.isEmpty
                      ? constraints.maxWidth
                      : math.max(bands.length * 2.0, constraints.maxWidth);
                  return Container(
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.08),
                      ),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: RepaintBoundary(
                          child: SizedBox(
                            width: contentWidth,
                            height: constraints.maxHeight,
                            child: CustomPaint(
                              painter: RawSpectrumPainter(bands),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}
