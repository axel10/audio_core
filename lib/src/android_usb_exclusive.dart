import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

/// Metadata for a connected Android USB Audio Class (UAC) device.
class UsbAudioDeviceInfo {
  const UsbAudioDeviceInfo({
    required this.deviceName,
    required this.productName,
    required this.manufacturerName,
    required this.vendorId,
    required this.productId,
    required this.hasPermission,
    required this.isActiveExclusive,
  });

  final String deviceName;
  final String productName;
  final String manufacturerName;
  final int vendorId;
  final int productId;
  final bool hasPermission;
  final bool isActiveExclusive;

  String get vidPidHex =>
      '${vendorId.toRadixString(16).padLeft(4, '0').toUpperCase()}:'
      '${productId.toRadixString(16).padLeft(4, '0').toUpperCase()}';

  factory UsbAudioDeviceInfo.fromMap(Map<Object?, Object?> map) {
    return UsbAudioDeviceInfo(
      deviceName: map['deviceName']?.toString() ?? '',
      productName: map['productName']?.toString() ?? 'USB Audio DAC',
      manufacturerName: map['manufacturerName']?.toString() ?? '',
      vendorId: (map['vendorId'] as num?)?.toInt() ?? 0,
      productId: (map['productId'] as num?)?.toInt() ?? 0,
      hasPermission: map['hasPermission'] == true,
      isActiveExclusive: map['isActiveExclusive'] == true,
    );
  }
}

/// Live telemetry snapshot from the Rust UAC 1.0 / 2.0 exclusive engine.
class UsbExclusiveStatus {
  const UsbExclusiveStatus({
    required this.exclusiveActive,
    required this.streamRunning,
    required this.paused,
    required this.deviceName,
    required this.vendorId,
    required this.productId,
    required this.uacVersion,
    required this.sampleRate,
    required this.channels,
    required this.bitDepth,
    required this.subslotSize,
    required this.hasFeedbackEndpoint,
    required this.playedFrames,
    required this.bufferedFrames,
    required this.underrunCount,
    required this.supportedSampleRates,
    this.lastError,
  });

  final bool exclusiveActive;
  final bool streamRunning;
  final bool paused;
  final String deviceName;
  final int vendorId;
  final int productId;
  final String uacVersion;
  final int sampleRate;
  final int channels;
  final int bitDepth;
  final int subslotSize;
  final bool hasFeedbackEndpoint;
  final int playedFrames;
  final int bufferedFrames;
  final int underrunCount;
  final List<int> supportedSampleRates;
  final String? lastError;

  static const UsbExclusiveStatus empty = UsbExclusiveStatus(
    exclusiveActive: false,
    streamRunning: false,
    paused: false,
    deviceName: '',
    vendorId: 0,
    productId: 0,
    uacVersion: 'none',
    sampleRate: 0,
    channels: 0,
    bitDepth: 0,
    subslotSize: 0,
    hasFeedbackEndpoint: false,
    playedFrames: 0,
    bufferedFrames: 0,
    underrunCount: 0,
    supportedSampleRates: <int>[],
  );

  factory UsbExclusiveStatus.fromJsonString(String raw) {
    if (raw.trim().isEmpty) return UsbExclusiveStatus.empty;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return UsbExclusiveStatus.empty;
      return UsbExclusiveStatus.fromJson(decoded);
    } catch (_) {
      return UsbExclusiveStatus.empty;
    }
  }

  factory UsbExclusiveStatus.fromJson(Map<String, dynamic> json) {
    final ratesRaw = json['supported_sample_rates'];
    final rates = <int>[];
    if (ratesRaw is List) {
      for (final item in ratesRaw) {
        if (item is num) rates.add(item.toInt());
      }
    }
    return UsbExclusiveStatus(
      exclusiveActive: json['exclusive_active'] == true,
      streamRunning: json['stream_running'] == true,
      paused: json['paused'] == true,
      deviceName: json['device_name']?.toString() ?? '',
      vendorId: (json['vendor_id'] as num?)?.toInt() ?? 0,
      productId: (json['product_id'] as num?)?.toInt() ?? 0,
      uacVersion: json['uac_version']?.toString() ?? 'none',
      sampleRate: (json['sample_rate'] as num?)?.toInt() ?? 0,
      channels: (json['channels'] as num?)?.toInt() ?? 0,
      bitDepth: (json['bit_depth'] as num?)?.toInt() ?? 0,
      subslotSize: (json['subslot_size'] as num?)?.toInt() ?? 0,
      hasFeedbackEndpoint: json['has_feedback_endpoint'] == true,
      playedFrames: (json['played_frames'] as num?)?.toInt() ?? 0,
      bufferedFrames: (json['buffered_frames'] as num?)?.toInt() ?? 0,
      underrunCount: (json['underrun_count'] as num?)?.toInt() ?? 0,
      supportedSampleRates: rates,
      lastError: json['last_error']?.toString(),
    );
  }
}

/// Result of toggling USB exclusive mode.
class UsbExclusiveToggleResult {
  const UsbExclusiveToggleResult({
    required this.ok,
    required this.status,
    this.error,
  });

  final bool ok;
  final UsbExclusiveStatus status;
  final String? error;
}

/// Event emitted when USB DAC devices are attached/detached or exclusive state changes.
class UsbExclusiveEvent {
  const UsbExclusiveEvent({
    required this.eventType,
    required this.status,
  });

  final String eventType;
  final UsbExclusiveStatus status;
}

/// Dart client for Android user-space USB Audio exclusive mode.
class AndroidUsbExclusiveService {
  AndroidUsbExclusiveService._();

  static final AndroidUsbExclusiveService instance = AndroidUsbExclusiveService._();

  static const MethodChannel _channel =
      MethodChannel('audio_core.usb_exclusive');
  static const EventChannel _eventChannel =
      EventChannel('audio_core.usb_exclusive/events');

  bool get isSupported => Platform.isAndroid;

  Stream<UsbExclusiveEvent>? _cachedEventStream;

  /// Stream of hotplug and exclusive-mode change events on Android.
  Stream<UsbExclusiveEvent> get events {
    if (!isSupported) {
      return const Stream<UsbExclusiveEvent>.empty();
    }
    return _cachedEventStream ??=
        _eventChannel.receiveBroadcastStream().map((dynamic raw) {
      if (raw is Map) {
        final eventType = raw['event']?.toString() ?? 'unknown';
        final statusJson = raw['statusJson']?.toString() ?? '';
        return UsbExclusiveEvent(
          eventType: eventType,
          status: UsbExclusiveStatus.fromJsonString(statusJson),
        );
      }
      return const UsbExclusiveEvent(
        eventType: 'unknown',
        status: UsbExclusiveStatus.empty,
      );
    });
  }

  /// List connected USB Audio Class (DAC / dongle) devices.
  Future<List<UsbAudioDeviceInfo>> listDevices() async {
    if (!isSupported) return const <UsbAudioDeviceInfo>[];
    final raw = await _channel.invokeMethod<List<Object?>>('listDevices');
    if (raw == null) return const <UsbAudioDeviceInfo>[];
    return raw
        .whereType<Map<Object?, Object?>>()
        .map(UsbAudioDeviceInfo.fromMap)
        .toList(growable: false);
  }

  /// Query live engine status (sample rate, bit depth, frames played, underruns).
  Future<UsbExclusiveStatus> getStatus() async {
    if (!isSupported) return UsbExclusiveStatus.empty;
    final raw = await _channel.invokeMethod<String>('getStatus');
    return UsbExclusiveStatus.fromJsonString(raw ?? '');
  }

  /// Enable or disable Android USB exclusive mode.
  ///
  /// When [enabled] is `true`, prompts for USB permission if needed, claims
  /// the USB DAC interfaces (detaching kernel `snd-usb-audio` so other apps
  /// have no sound), and routes ExoPlayer PCM output directly to the DAC.
  Future<UsbExclusiveToggleResult> setExclusiveMode({
    required bool enabled,
    String? deviceName,
  }) async {
    if (!isSupported) {
      return const UsbExclusiveToggleResult(
        ok: false,
        status: UsbExclusiveStatus.empty,
        error: 'USB exclusive mode is only supported on Android',
      );
    }
    final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
      'setExclusiveMode',
      <String, Object?>{
        'enabled': enabled,
        if (deviceName != null) 'deviceName': deviceName,
      },
    );
    final ok = raw?['ok'] == true;
    final error = raw?['error']?.toString();
    final statusJson = raw?['statusJson']?.toString() ?? '';
    return UsbExclusiveToggleResult(
      ok: ok,
      status: UsbExclusiveStatus.fromJsonString(statusJson),
      error: error,
    );
  }
}
