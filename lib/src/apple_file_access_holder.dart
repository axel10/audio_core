/// Apple 安全作用域授权的持有者标识。
///
/// 原生侧按 `(scope 路径, holder)` 分账：只有打开它的那一方才能减掉自己那份，
/// 全部 holder 都放掉才真正 `stopAccessingSecurityScopedResource()`。
/// 因此 begin 和 end 必须传同一个值，且不同模块不要复用同一个字符串——
/// 复用了就等于又退回「一个整数大家共用」的老问题。
abstract final class AppleFileAccessHolder {
  /// 曲库根目录的常驻授权（`ScannerService`）。
  static const String scanner = 'scanner';

  /// 播放链路的当前曲目（音频引擎 / 播放控制器）。
  static const String playback = 'playback';

  /// LAN 分享目录（发送端与接收端）。
  static const String sharing = 'sharing';

  /// 音频转码的输入与输出目录。
  static const String converter = 'converter';

  /// 一次性的短时写租约（写标签、覆盖文件），begin/end 必须成对。
  static const String writer = 'writer';

  /// 一次性的短时读租约（波形、PCM、时长探测）。
  static const String reader = 'reader';

  /// 未显式声明 holder 的调用方，必须与原生侧默认值一致。
  static const String fallback = 'default';
}
