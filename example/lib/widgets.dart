import 'dart:io';
import 'package:flutter/material.dart';
import 'package:audio_core/audio_core.dart';
import 'package:cross_file/cross_file.dart';
import 'package:desktop_drop/desktop_drop.dart';

class AudioDropRegion extends StatefulWidget {
  const AudioDropRegion({
    super.key,
    required this.controller,
    required this.child,
    this.overlayText = 'Drag an audio file here',
    this.onTracksAccepted,
  });

  final AudioCoreController controller;
  final Widget child;
  final String overlayText;
  final Future<void> Function(List<AudioTrack> tracks)? onTracksAccepted;

  @override
  State<AudioDropRegion> createState() => _AudioDropRegionState();
}

class _AudioDropRegionState extends State<AudioDropRegion> {
  bool _isDragging = false;

  bool get _enabled => Platform.isWindows || Platform.isLinux;

  Future<void> _handleDrop(List<XFile> files) async {
    if (!_enabled || files.isEmpty) {
      return;
    }
    if (!widget.controller.isInitialized) {
      await widget.controller.initialize();
    }
    final List<AudioTrack> tracks = [];
    for (final file in files) {
      final path = file.path;
      if (path.isNotEmpty && File(path).existsSync()) {
        tracks.add(
          AudioTrack(
            id: path,
            title: file.name,
            uri: path,
            metadata: <String, Object?>{'isLike': false, 'playCount': 0},
          ),
        );
      }
    }
    if (tracks.isEmpty) return;

    final handler = widget.onTracksAccepted;
    if (handler != null) {
      await handler(tracks);
      return;
    }

    await widget.controller.playlist.addTracks(tracks);
    if (!widget.controller.player.isPlaying &&
        widget.controller.player.currentPath != null) {
      await widget.controller.player.play();
    }
  }

  @override
  Widget build(BuildContext context) {
    return DropTarget(
      enable: _enabled,
      onDragEntered: (_) => setState(() => _isDragging = true),
      onDragExited: (_) => setState(() => _isDragging = false),
      onDragDone: (detail) async {
        setState(() => _isDragging = false);
        await _handleDrop(detail.files);
      },
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _isDragging ? const Color(0xFF2AD4FF) : Colors.transparent,
            width: 2,
          ),
        ),
        child: Stack(
          children: [
            widget.child,
            if (_enabled && widget.controller.player.currentPath == null)
              Center(
                child: Text(
                  widget.overlayText,
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class WaveformPainter extends CustomPainter {
  WaveformPainter(this.waveform, this.progress);

  final List<double> waveform;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    if (waveform.isEmpty) return;

    final barWidth = size.width / waveform.length;
    final maxBarHeight = size.height;

    final playedPaint = Paint()
      ..color = Colors.blue
      ..style = PaintingStyle.fill;

    final unplayedPaint = Paint()
      ..color = Colors.grey.withValues(alpha: 0.5)
      ..style = PaintingStyle.fill;

    for (var i = 0; i < waveform.length; i++) {
      final value = waveform[i];
      final height = (value * maxBarHeight).clamp(2.0, maxBarHeight);
      final left = i * barWidth;
      final top = (maxBarHeight - height) / 2; // Center vertically

      final rect = Rect.fromLTWH(left, top, barWidth - 1, height);
      final isPlayed = (i / waveform.length) <= progress;

      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(2)),
        isPlayed ? playedPaint : unplayedPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant WaveformPainter oldDelegate) {
    return true;
  }
}

class DemoSpectrumPainter extends CustomPainter {
  DemoSpectrumPainter(this.bands, {this.color});

  final List<double> bands;
  final Color? color;

  @override
  void paint(Canvas canvas, Size size) {
    if (bands.isEmpty) {
      return;
    }
    const safeTop = 6.0;
    const safeBottom = 6.0;
    const gap = 2.0;
    const minBarHeight = 2.0;
    final usableHeight = (size.height - safeTop - safeBottom).clamp(
      0.0,
      size.height,
    );
    final barWidth = ((size.width - (bands.length + 1) * gap) / bands.length)
        .clamp(1.0, 20.0);

    final bodyColor = color ?? const Color(0xFF2AD4FF);
    final bodyPaint = Paint()..color = bodyColor;
    final glowPaint = Paint()
      ..color = bodyColor.withValues(alpha: 0.5)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
    final baseline = size.height - safeBottom;

    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, safeTop, size.width, usableHeight));
    for (var i = 0; i < bands.length; i++) {
      final v = bands[i].clamp(0.0, 1.0);
      final h = (v * usableHeight).clamp(minBarHeight, usableHeight);
      final left = gap + i * (barWidth + gap);
      final top = baseline - h;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(left, top, barWidth, h),
        const Radius.circular(2),
      );
      canvas.drawRRect(rect, glowPaint);
      canvas.drawRRect(rect, bodyPaint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant DemoSpectrumPainter oldDelegate) {
    return oldDelegate.bands != bands || oldDelegate.color != color;
  }
}
