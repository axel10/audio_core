import 'dart:async';
import 'dart:io';

import 'package:audio_core/audio_core.dart';
import 'package:flutter/material.dart';

/// Demo tab for testing Android user-space USB Audio exclusive mode (UAC 1.0 / 2.0).
class UsbExclusiveTab extends StatefulWidget {
  const UsbExclusiveTab({
    super.key,
    required this.controller,
    required this.onPickAudio,
  });

  final AudioCoreController controller;
  final VoidCallback onPickAudio;

  @override
  State<UsbExclusiveTab> createState() => _UsbExclusiveTabState();
}

class _UsbExclusiveTabState extends State<UsbExclusiveTab> {
  final AndroidUsbExclusiveService _usb = AndroidUsbExclusiveService.instance;

  List<UsbAudioDeviceInfo> _devices = const <UsbAudioDeviceInfo>[];
  String? _selectedDeviceName;
  UsbExclusiveStatus _status = UsbExclusiveStatus.empty;
  bool _busy = false;
  String? _message;
  String? _error;

  StreamSubscription<UsbExclusiveEvent>? _eventSub;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    if (_usb.isSupported) {
      _refreshAll();
      _eventSub = _usb.events.listen((event) {
        if (!mounted) return;
        setState(() {
          _status = event.status;
          _message = 'USB event: ${event.eventType}';
        });
        _refreshDevicesOnly();
      });
      _pollTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (_status.exclusiveActive) {
          _refreshStatusOnly();
        }
      });
    }
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _refreshAll() async {
    await Future.wait(<Future<void>>[
      _refreshDevicesOnly(),
      _refreshStatusOnly(),
    ]);
  }

  Future<void> _refreshDevicesOnly() async {
    try {
      final list = await _usb.listDevices();
      if (!mounted) return;
      setState(() {
        _devices = list;
        if (_selectedDeviceName == null ||
            !list.any((d) => d.deviceName == _selectedDeviceName)) {
          _selectedDeviceName = list.isNotEmpty ? list.first.deviceName : null;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Failed to list USB devices: $e');
    }
  }

  Future<void> _refreshStatusOnly() async {
    try {
      final st = await _usb.getStatus();
      if (!mounted) return;
      setState(() => _status = st);
    } catch (_) {}
  }

  Future<void> _toggleExclusive(bool enable) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _message = enable ? 'Requesting USB DAC exclusive access...' : 'Releasing USB DAC...';
    });

    try {
      final res = await _usb.setExclusiveMode(
        enabled: enable,
        deviceName: enable ? _selectedDeviceName : null,
      );
      if (!mounted) return;
      setState(() {
        _status = res.status;
        _error = res.ok ? null : (res.error ?? 'Unknown error');
        _message = res.ok
            ? (enable
                ? 'USB Exclusive Mode ACTIVE (other apps muted)'
                : 'USB Exclusive Mode disabled (system audio restored)')
            : null;
      });
      await _refreshDevicesOnly();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Toggle failed: $e';
        _message = null;
      });
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isAndroid) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Android USB Exclusive Mode (UAC 1.0 / 2.0 via libusb) is only available on Android devices.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final scheme = Theme.of(context).colorScheme;
    final active = _status.exclusiveActive;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            color: active ? scheme.primaryContainer : null,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        active ? Icons.usb : Icons.usb_off,
                        color: active ? scheme.primary : scheme.outline,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          active ? 'USB Exclusive Mode: ON' : 'USB Exclusive Mode: OFF',
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                        ),
                      ),
                      Switch(
                        value: active,
                        onChanged: _busy ? null : _toggleExclusive,
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    active
                        ? 'Kernel snd-usb-audio is detached. Other apps have no audio output on this USB DAC.'
                        : 'Connect a USB DAC / dongle, select it below, and toggle ON to claim exclusive access.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (_message != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _message!,
                      style: TextStyle(color: scheme.primary, fontSize: 12),
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _error!,
                      style: TextStyle(color: scheme.error, fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        'Connected USB Audio Devices (${_devices.length})',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: 'Refresh USB devices',
                        onPressed: _busy ? null : _refreshAll,
                        icon: const Icon(Icons.refresh),
                      ),
                    ],
                  ),
                  if (_devices.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        'No USB Audio Class DAC detected. Plug in a USB-C DAC / dongle and tap Refresh.',
                      ),
                    )
                  else
                    for (final dev in _devices)
                      RadioListTile<String>(
                        dense: true,
                        value: dev.deviceName,
                        groupValue: _selectedDeviceName,
                        onChanged: _busy
                            ? null
                            : (val) => setState(() => _selectedDeviceName = val),
                        title: Text(dev.productName),
                        subtitle: Text(
                          'VID:PID ${dev.vidPidHex} • '
                          '${dev.hasPermission ? 'Permitted' : 'Needs permission'}'
                          '${dev.isActiveExclusive ? ' • EXCLUSIVE' : ''}',
                        ),
                      ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Live DAC Telemetry',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  _kv('Device', _status.deviceName.isEmpty ? '-' : _status.deviceName),
                  _kv('Protocol', _status.uacVersion),
                  _kv(
                    'Active Format',
                    _status.sampleRate > 0
                        ? '${_status.sampleRate} Hz / ${_status.bitDepth}-bit '
                            '(${_status.subslotSize}B slot) / ${_status.channels} ch'
                        : 'Idle (start playback to configure)',
                  ),
                  _kv(
                    'Stream State',
                    _status.streamRunning
                        ? (_status.paused ? 'Paused (sending silence)' : 'Streaming')
                        : 'Stopped',
                  ),
                  _kv(
                    'Clock Sync',
                    _status.hasFeedbackEndpoint
                        ? 'Async Explicit Feedback'
                        : 'Fractional Nominal Scheduler',
                  ),
                  _kv('Played Frames', '${_status.playedFrames}'),
                  _kv('Buffered Frames', '${_status.bufferedFrames}'),
                  _kv('Underruns', '${_status.underrunCount}'),
                  _kv(
                    'Supported Rates',
                    _status.supportedSampleRates.isEmpty
                        ? '-'
                        : _status.supportedSampleRates
                            .map((r) => '${(r / 1000).toStringAsFixed(1)}k')
                            .join(', '),
                  ),
                  if (_status.lastError != null && _status.lastError!.isNotEmpty)
                    _kv('Last Error', _status.lastError!),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          AnimatedBuilder(
            animation: widget.controller,
            builder: (context, _) {
              final player = widget.controller.player;
              final track = widget.controller.playlist.currentTrack;
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Quick Playback Test',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        track?.title ?? player.currentPath ?? 'No track selected',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 10,
                        runSpacing: 8,
                        children: [
                          ElevatedButton.icon(
                            onPressed: widget.onPickAudio,
                            icon: const Icon(Icons.library_music),
                            label: const Text('Select Audio'),
                          ),
                          ElevatedButton.icon(
                            onPressed: player.currentPath == null
                                ? null
                                : () => player.togglePlayPause(),
                            icon: Icon(
                              player.isPlaying ? Icons.pause : Icons.play_arrow,
                            ),
                            label: Text(player.isPlaying ? 'Pause' : 'Play'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _kv(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 125,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
