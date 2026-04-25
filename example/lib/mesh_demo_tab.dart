import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';
import 'package:flutter/material.dart';
import 'package:mesh_gradient/mesh_gradient.dart';
import 'package:palette_generator/palette_generator.dart' as legacy_palette;
import 'package:palette_generator_master/palette_generator_master.dart'
    as master_palette;

class MeshDemoTab extends StatefulWidget {
  const MeshDemoTab({super.key, required this.controller});

  final AudioCoreController controller;

  @override
  State<MeshDemoTab> createState() => _MeshDemoTabState();
}

class _MeshDemoTabState extends State<MeshDemoTab> {
  static const List<Color> _fallbackColors = <Color>[
    Color(0xFFF43F5E),
    Color(0xFF22D3EE),
    Color(0xFFF59E0B),
    Color(0xFF818CF8),
  ];

  late final Directory _cacheRoot;
  double _hueCohesion = 0.58;
  bool _showUi = true;
  List<Color> _meshColors = _fallbackColors;
  List<_MeshThemePreset> _themePresets = const [];
  String _activeThemeSource = 'auto';
  bool _isLoading = false;
  String? _statusText;
  String? _errorText;
  String? _trackedKey;
  Timer? _debounceTimer;
  int _requestToken = 0;

  @override
  void initState() {
    super.initState();
    _cacheRoot = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}audio_core_mesh_demo',
    )..createSync(recursive: true);
    widget.controller.addListener(_handleControllerChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _refreshPalette(immediate: true);
      }
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerChanged);
    _debounceTimer?.cancel();
    super.dispose();
  }

  void _handleControllerChanged() {
    final nextKey = _currentTrackKey();
    if (nextKey == _trackedKey) {
      return;
    }
    _refreshPalette(immediate: true);
  }

  void _toggleUiVisibility() {
    setState(() {
      _showUi = !_showUi;
    });
  }

  String? _currentTrackKey() {
    final track = widget.controller.playlist.currentTrack;
    if (track == null) return null;
    return '${track.id}|${widget.controller.player.currentPath ?? track.uri}';
  }

  Future<void> _refreshPalette({required bool immediate}) async {
    _debounceTimer?.cancel();
    if (immediate) {
      unawaited(_loadPaletteSnapshot());
      return;
    }

    _debounceTimer = Timer(const Duration(milliseconds: 90), () {
      unawaited(_loadPaletteSnapshot());
    });
  }

  Future<void> _loadPaletteSnapshot() async {
    final track = widget.controller.playlist.currentTrack;
    final path = widget.controller.player.currentPath ?? track?.uri;
    final trackKey = _currentTrackKey();
    final requestToken = ++_requestToken;

    if (track == null || path == null || path.isEmpty) {
      if (!mounted) return;
      setState(() {
        _trackedKey = trackKey;
        _meshColors = _fallbackColors;
        _themePresets = const [];
        _activeThemeSource = 'auto';
        _statusText = 'Load a song with embedded artwork to drive the mesh.';
        _errorText = null;
        _isLoading = false;
      });
      return;
    }

    if (!mounted) return;
    setState(() {
      _trackedKey = trackKey;
      _isLoading = true;
      _errorText = null;
      _statusText =
          'Sampling embedded artwork for ${track.title ?? track.artist ?? track.uri}';
    });

    try {
      final artwork = await widget.controller.generateTrackArtwork(
        path: path,
        cacheRootPath: _cacheRoot.path,
        saveLargeArtwork: false,
        hueCohesion: _hueCohesion,
      );
      if (!mounted || requestToken != _requestToken) return;

      final colors = _colorsFromArtwork(artwork.themeColorsBlob);
      final themePresets = await _buildThemePresets(
        artwork: artwork,
        autoColors: colors,
      );
      if (!mounted || requestToken != _requestToken) return;
      setState(() {
        _meshColors = colors;
        _themePresets = themePresets;
        _activeThemeSource = 'auto';
        _statusText = artwork.artworkFound
            ? 'Using ${artwork.artworkWidth ?? 0}x${artwork.artworkHeight ?? 0} cover artwork'
            : 'No embedded artwork found, using fallback colors';
        _errorText = null;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted || requestToken != _requestToken) return;
      setState(() {
        _meshColors = _fallbackColors;
        _themePresets = const [];
        _activeThemeSource = 'auto';
        _statusText = 'Failed to sample artwork colors';
        _errorText = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<List<_MeshThemePreset>> _buildThemePresets({
    required GeneratedTrackArtwork artwork,
    required List<Color> autoColors,
  }) async {
    final presets = <_MeshThemePreset>[
      _MeshThemePreset(
        sourceId: 'auto',
        title: 'Auto / backend',
        subtitle: 'Current cover via Rust palette',
        colors: autoColors,
      ),
    ];

    final thumbnailPath = artwork.thumbnailPath;
    if (thumbnailPath == null || thumbnailPath.isEmpty) {
      return presets;
    }

    final thumbnailFile = File(thumbnailPath);
    if (!thumbnailFile.existsSync()) {
      return presets;
    }

    final imageProvider = FileImage(thumbnailFile);
    final size = Size(
      generatedArtworkThumbnailSize.toDouble(),
      generatedArtworkThumbnailSize.toDouble(),
    );

    final results = await Future.wait([
      legacy_palette.PaletteGenerator.fromImageProvider(
        imageProvider,
        size: size,
        maximumColorCount: 12,
      ),
      master_palette.PaletteGeneratorMaster.fromImageProvider(
        imageProvider,
        size: size,
        maximumColorCount: 12,
        generateHarmony: false,
      ),
    ]);

    presets.add(
      _MeshThemePreset(
        sourceId: 'palette_generator',
        title: 'palette_generator',
        subtitle: 'Current cover via package 0.3.3+7',
        colors: _colorsFromLegacyPalette(
          results[0] as legacy_palette.PaletteGenerator,
        ),
      ),
    );
    presets.add(
      _MeshThemePreset(
        sourceId: 'palette_generator_master',
        title: 'palette_generator_master',
        subtitle: 'Current cover via master package',
        colors: _colorsFromMasterPalette(
          results[1] as master_palette.PaletteGeneratorMaster,
        ),
      ),
    );

    return presets;
  }

  List<Color> _colorsFromArtwork(Uint8List? blob) {
    if (blob == null || blob.isEmpty) {
      return _fallbackColors;
    }

    try {
      final decoded = jsonDecode(utf8.decode(blob));
      if (decoded is Map) {
        final themeColors = decoded.map<String, int>((key, value) {
          if (value is num) {
            return MapEntry(key.toString(), value.toInt());
          }
          throw const FormatException(
            'Theme colors blob contains non-numeric values.',
          );
        });
        return _resolveMeshColors(themeColors);
      }
    } catch (_) {
      // Fall back to the default palette below.
    }

    return _fallbackColors;
  }

  Color _resolveMeshColor(
    Map<String, int> themeColors,
    List<String> keys, {
    required Color fallback,
  }) {
    for (final key in keys) {
      final value = themeColors[key];
      if (value != null) {
        return Color(value);
      }
    }
    return fallback;
  }

  List<Color> _resolveMeshColors(Map<String, int> themeColors) {
    final color1 = _resolveMeshColor(themeColors, const [
      'dominant',
      'vibrant',
    ], fallback: Colors.white);
    final color2 = _resolveMeshColor(themeColors, const [
      'vibrant',
      'muted',
    ], fallback: Colors.black);
    final color3 = _resolveMeshColor(themeColors, const [
      'lightVibrant',
      'muted',
    ], fallback: Colors.black);
    final color4 = _resolveMeshColor(themeColors, const [
      'darkVibrant',
      'darkMuted',
    ], fallback: Colors.black);

    return <Color>[color1, color2, color3, color4];
  }

  List<Color> _colorsFromLegacyPalette(
    legacy_palette.PaletteGenerator palette,
  ) {
    return <Color>[
      _pickPaletteColor(palette.dominantColor, fallback: _fallbackColors[0]),
      _pickPaletteColor(palette.vibrantColor, fallback: _fallbackColors[1]),
      _pickPaletteColor(
        palette.lightVibrantColor ?? palette.lightMutedColor,
        fallback: _fallbackColors[2],
      ),
      _pickPaletteColor(
        palette.darkVibrantColor ?? palette.darkMutedColor,
        fallback: _fallbackColors[3],
      ),
    ];
  }

  List<Color> _colorsFromMasterPalette(
    master_palette.PaletteGeneratorMaster palette,
  ) {
    return <Color>[
      _pickPaletteColor(palette.dominantColor, fallback: _fallbackColors[0]),
      _pickPaletteColor(palette.vibrantColor, fallback: _fallbackColors[1]),
      _pickPaletteColor(
        palette.lightVibrantColor ?? palette.lightMutedColor,
        fallback: _fallbackColors[2],
      ),
      _pickPaletteColor(
        palette.darkVibrantColor ?? palette.darkMutedColor,
        fallback: _fallbackColors[3],
      ),
    ];
  }

  Color _pickPaletteColor(Object? paletteColor, {required Color fallback}) {
    if (paletteColor is legacy_palette.PaletteColor) {
      return paletteColor.color;
    }
    if (paletteColor is master_palette.PaletteColorMaster) {
      return paletteColor.color;
    }
    return fallback;
  }

  void _applyThemePreset(_MeshThemePreset preset) {
    setState(() {
      _meshColors = preset.colors;
      _activeThemeSource = preset.sourceId;
      _statusText = 'Applied ${preset.title} from the current cover';
      _errorText = null;
    });
  }

  String _formatHex(Color color) {
    final rgb = color.toARGB32() & 0x00ffffff;
    return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }

  Widget _buildGlassCard({
    required BuildContext context,
    required Widget child,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentTrack = widget.controller.playlist.currentTrack;
    final title = currentTrack?.title?.trim();
    final artist = currentTrack?.artist?.trim();
    final album = currentTrack?.album?.trim();
    final subtitle = <String>[
      if (artist != null && artist.isNotEmpty) artist,
      if (album != null && album.isNotEmpty) album,
      currentTrack?.uri ?? 'No track loaded',
    ].join(' • ');

    return Stack(
      children: [
        Positioned.fill(
          child: AnimatedMeshGradient(
            colors: _meshColors,
            options: AnimatedMeshGradientOptions(
              frequency: 5.2,
              amplitude: 32,
              speed: 0.04,
              grain: 0.03,
            ),
          ),
        ),
        if (_showUi)
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.16),
                    Colors.black.withValues(alpha: 0.34),
                  ],
                ),
              ),
            ),
          ),
        if (_showUi)
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildGlassCard(
                    context: context,
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.blur_on, size: 34),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Mesh Artwork Lab',
                                      style: Theme.of(
                                        context,
                                      ).textTheme.headlineSmall,
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      'The mesh colors come from the current song cover, then the slider retunes hue cohesion in real time.',
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodyMedium,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Text(
                            title == null || title.isEmpty
                                ? 'No track selected'
                                : title,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            subtitle,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 16),
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: [
                              Chip(
                                avatar: const Icon(
                                  Icons.palette_outlined,
                                  size: 18,
                                ),
                                label: Text(
                                  '${_hueCohesion.toStringAsFixed(2)} hue cohesion',
                                ),
                              ),
                              Chip(
                                avatar: const Icon(
                                  Icons.auto_awesome,
                                  size: 18,
                                ),
                                label: Text(
                                  _isLoading
                                      ? 'Sampling cover'
                                      : 'Live mesh background',
                                ),
                              ),
                            ],
                          ),
                          if (_themePresets.isNotEmpty) ...[
                            const SizedBox(height: 16),
                            Text(
                              'Tap a cover-derived palette to apply it to the mesh.',
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 12,
                              runSpacing: 12,
                              children: _themePresets
                                  .map((preset) {
                                    final selected =
                                        _activeThemeSource == preset.sourceId;
                                    return _ThemePresetButton(
                                      preset: preset,
                                      selected: selected,
                                      onPressed: () =>
                                          _applyThemePreset(preset),
                                    );
                                  })
                                  .toList(growable: false),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _buildGlassCard(
                    context: context,
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.tune,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Hue Cohesion',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Drag the slider to see the artwork palette tighten or loosen around the cover art hues.',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          const SizedBox(height: 12),
                          Slider(
                            value: _hueCohesion,
                            min: 0.0,
                            max: 1.0,
                            divisions: 100,
                            label: _hueCohesion.toStringAsFixed(2),
                            onChanged: (value) {
                              setState(() => _hueCohesion = value);
                              _refreshPalette(immediate: false);
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _buildGlassCard(
                    context: context,
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.color_lens_outlined,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Mesh Colors',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 12,
                            runSpacing: 12,
                            children: List.generate(_meshColors.length, (
                              index,
                            ) {
                              final color = _meshColors[index];
                              return _ColorSwatch(
                                color: color,
                                label: _formatHex(color),
                              );
                            }),
                          ),
                          if (_statusText != null) ...[
                            const SizedBox(height: 16),
                            Text(
                              _statusText!,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ],
                          if (_errorText != null) ...[
                            const SizedBox(height: 8),
                            Text(
                              _errorText!,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(context).colorScheme.error,
                                  ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        Positioned(
          top: 12,
          right: 12,
          child: SafeArea(
            child: IconButton.filledTonal(
              onPressed: _toggleUiVisibility,
              icon: Icon(_showUi ? Icons.fullscreen : Icons.dashboard_outlined),
              tooltip: _showUi ? 'Hide UI' : 'Show UI',
            ),
          ),
        ),
      ],
    );
  }
}

class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    final onColor =
        ThemeData.estimateBrightnessForColor(color) == Brightness.dark
        ? Colors.white
        : Colors.black;

    return Container(
      width: 110,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.34),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: onColor,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Artwork',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: onColor.withValues(alpha: 0.82),
            ),
          ),
        ],
      ),
    );
  }
}

class _ThemePresetButton extends StatelessWidget {
  const _ThemePresetButton({
    required this.preset,
    required this.selected,
    required this.onPressed,
  });

  final _MeshThemePreset preset;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final outlineColor = selected
        ? Theme.of(context).colorScheme.primary
        : Colors.white.withValues(alpha: 0.18);

    return Material(
      color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.72),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width: 180,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: outlineColor, width: selected ? 1.5 : 1),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      preset.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (selected)
                    Icon(
                      Icons.check_circle,
                      size: 18,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                preset.subtitle,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  for (int i = 0; i < preset.colors.length; i++)
                    Expanded(
                      child: Container(
                        height: 14,
                        margin: EdgeInsets.only(
                          right: i == preset.colors.length - 1 ? 0 : 4,
                        ),
                        decoration: BoxDecoration(
                          color: preset.colors[i],
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MeshThemePreset {
  const _MeshThemePreset({
    required this.sourceId,
    required this.title,
    required this.subtitle,
    required this.colors,
  });

  final String sourceId;
  final String title;
  final String subtitle;
  final List<Color> colors;
}
