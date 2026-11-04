import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// iOS 外部打开（文件 app 里「用 Vynody 打开」、共享菜单等）的事件入口。
///
/// 授权动作全部在原生 `scene(_:openURLContexts:)` 里完成：security scope 只挂在
/// 系统递过来的那个原始 URL 上，回调返回即失效，Dart 侧拿到路径时已经补不回来。
/// 这里只做两件事：把原生回推的路径转成流；取回冷启动阶段攒下的路径。
abstract final class AppleOpenedFiles {
  static const MethodChannel _channel = MethodChannel('audio_core.player');

  static final StreamController<List<String>> _events =
      StreamController<List<String>>.broadcast();

  static bool _attached = false;

  /// 外部打开的文件路径批次。订阅方决定是播放还是入队。
  static Stream<List<String>> get events => _events.stream;

  /// 挂上通道处理器，并取回「冷启动时插件尚未就绪」阶段攒下的路径。
  ///
  /// 重复调用无副作用；非 iOS 平台直接返回空列表。
  static Future<List<String>> attach() async {
    if (!Platform.isIOS) return const <String>[];

    if (!_attached) {
      _attached = true;
      _channel.setMethodCallHandler((call) async {
        if (call.method != 'onOpenFiles') return null;
        final arguments = call.arguments;
        final paths = arguments is List
            ? arguments.whereType<String>().toList(growable: false)
            : const <String>[];
        if (paths.isNotEmpty && !_events.isClosed) {
          _events.add(paths);
        }
        return null;
      });
    }

    try {
      final pending = await _channel.invokeListMethod<String>(
        'getPendingOpenedFiles',
      );
      return pending ?? const <String>[];
    } catch (_) {
      return const <String>[];
    }
  }
}
