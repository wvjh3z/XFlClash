/// Sentry crash 上报装配（NFR-7 / DD-14 链式 / DD-23 8 类 tag / κ-4 GDPR opt-out / 决策 #5）。
///
/// **改用 `SentryFlutter.init`**（2026-06-29 修订；原决策 #5 用基础 `Sentry.init` 不接管）：
/// 装**原生崩溃处理器**（Android NDK / ANR + Go 核心 `libclash.so` SIGSEGV —— VPN 客户端
/// 此前的最大监控盲区）。FlClash 的 `commonPrint` handler 在 `attach()`（runApp **后**）才硬设
/// `FlutterError.onError`、会覆盖 SDK 装的 handler，故由 [rechainFlutterError]（attach 完成后调）
/// 重链：先 Sentry 上报再调 FlClash handler，二者都不丢（修原 base-init 被 attach 覆盖的盲区）。
///
/// **§ C 配置（κ-4 GDPR）**：sendDefaultPii=false + tracesSampleRate=0 + beforeSend 过滤
/// token/password/email/uuid。`dsn==null`（dev / 用户 opt-out）全 no-op。
///
/// **DD-23 8 类 tag**：bootstrap.stage / envelope_source / decryption_failure / endpoint.current /
/// endpoint.race_attempts / auth.state / connectivity.online / flavor.id。
///
/// **实施期说明**：真实 `Sentry.init`（基础 init，非 `SentryFlutter.init`）在 [installEarly]
/// 触发（仅 dsn 非空时）；dsn==null 全 no-op（dev / opt-out / headless 测试）。
library;

import 'package:flutter/foundation.dart' show FlutterError, FlutterErrorDetails;
import 'package:sentry_flutter/sentry_flutter.dart';

/// Sentry tag key（DD-23 8 类）。
class SentryTagKeys {
  static const bootstrapStage = 'bootstrap.stage';
  static const envelopeSource = 'bootstrap.envelope_source';
  static const decryptionFailure = 'bootstrap.decryption_failure';
  static const endpointCurrent = 'endpoint.current';
  static const endpointRaceAttempts = 'endpoint.race_attempts';
  static const authState = 'auth.state';
  static const connectivityOnline = 'connectivity.online';
  static const flavorId = 'flavor.id';
}

/// 敏感字段（beforeSend 过滤；κ-4 / § C）。
const List<String> kSensitiveKeys = [
  'token',
  'password',
  'pwd',
  'email',
  'uuid',
  'authorization',
  'auth_data',
];

/// Sentry 装配（纯逻辑 + 装配；dsn null 全 no-op）。
class SentryBootstrap {
  SentryBootstrap._();

  static String? _dsn;
  static bool _enabled = false;
  static final Map<String, String> _tags = {};

  /// 是否已启用（dsn 非空 + 用户未 opt-out）。
  static bool get isEnabled => _enabled;

  /// 当前 tag 快照（测试 / 调试用）。
  static Map<String, String> get tagsSnapshot => Map.unmodifiable(_tags);

  /// 早期装配（bootstrap step 2）。dsn==null → no-op（dev / opt-out，§ C）。
  ///
  /// `SentryFlutter.init`（仅 dsn 非空时）装原生崩溃 + Dart 错误集成（FlutterError /
  /// PlatformDispatcher.onError 由 SDK 自动装，链式调 init 前旧 handler）。把同步阶段已累积的
  /// tag 灌进 scope。⚠️ FlClash `attach()`（runApp 后）会覆盖 FlutterError.onError，需
  /// [rechainFlutterError] 在 attach 完成后补回（见类注释）。
  static Future<void> installEarly({
    required String? dsn,
    required String release,
    String? environment,
    bool sendDefaultPii = false, // κ-4 默认 false
    double tracesSampleRate = 0.0, // v0.1 = 0
    bool userOptedOut = false, // κ-4 opt-out（默认 ON → false）
  }) async {
    _dsn = dsn;
    _enabled = dsn != null && dsn.isNotEmpty && !userOptedOut;
    if (!_enabled) return; // no-op（dev / opt-out / headless 测试）

    // SentryFlutter.init（非基础 Sentry.init）：装**原生**崩溃处理器（Android NDK/ANR +
    // Go 核心 libclash.so SIGSEGV）+ Dart 错误集成。FlutterError/PlatformDispatcher 集成由
    // SDK 自动装并链式调 init 前旧 handler；FlClash commonPrint 在 attach()（runApp 后）才设、
    // 会覆盖 FlutterError.onError → 由 rechainFlutterError（attach 后调）补回 Sentry 捕获。
    await SentryFlutter.init((options) {
      options.dsn = dsn;
      options.release = release;
      if (environment != null && environment.isNotEmpty) {
        options.environment = environment;
      }
      options.sendDefaultPii = sendDefaultPii; // κ-4：不发默认 PII（IP / 用户名等）
      options.tracesSampleRate = tracesSampleRate; // v0.1=0（不做 performance）
      // 隐私（§ C）：不抓截图（默认 false，显式锁定，避免泄露界面内容）。
      options.attachScreenshot = false;
      // 注：sendDefaultPii=false + 后台 Data Scrubber（Settings → Security & Privacy 开
      // 默认 scrubber + 补 email/uuid/token 字段）双层 PII 防护。scrubData() 保留为纯工具
      // （单测覆盖），供日后结构化 contexts 脱敏复用。
    });

    // 把同步阶段 installEarly 之前已累积的 tag（flavor.id / bootstrap.stage 等）灌进 scope。
    await Sentry.configureScope((scope) {
      _tags.forEach(scope.setTag);
    });
  }

  /// attach() 后重链 `FlutterError.onError`（修 SDK 集成被 FlClash `_initApp` 硬覆盖的盲区）。
  ///
  /// FlClash 在 `globalState.attach()`（runApp 后、晚于 [installEarly]）里硬设
  /// `FlutterError.onError = commonPrint`，覆盖 SentryFlutter 集成装的 handler。本方法在 attach
  /// 完成后（xboard_module 监听 initProvider==true）调用：取当前（FlClash 的）handler 包一层 ——
  /// 先 `Sentry.captureException` 再调 FlClash handler，二者都不丢。dsn 空 → no-op；幂等可重复调。
  static void rechainFlutterError() {
    if (!_enabled) return;
    final flclashHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      // ignore: discarded_futures
      Sentry.captureException(details.exception, stackTrace: details.stack);
      flclashHandler?.call(details);
    };
  }

  /// 上报「永不抛」层吞掉的异常（#2：bootstrap / 反腐层吞前尽力上报，避免静默失败盲飞）。
  /// dsn 空 → no-op。[where] 作 tag `swallowed.where`，便于在 Sentry 按吞咽点聚合。
  static void captureException(Object error,
      {StackTrace? stackTrace, String? where}) {
    if (!_enabled) return;
    // ignore: discarded_futures
    Sentry.captureException(
      error,
      stackTrace: stackTrace,
      withScope:
          where == null ? null : (scope) => scope.setTag('swallowed.where', where),
    );
  }

  /// beforeSend 脱敏：递归把敏感字段值替换为 '***'（κ-4 / § C）。
  /// 返回脱敏后的 map（纯函数，便于单测）。
  static Map<String, dynamic> scrubData(Map<String, dynamic> data) {
    final out = <String, dynamic>{};
    data.forEach((k, v) {
      if (kSensitiveKeys.any((s) => k.toLowerCase().contains(s))) {
        out[k] = '***';
      } else if (v is Map<String, dynamic>) {
        out[k] = scrubData(v);
      } else {
        out[k] = v;
      }
    });
    return out;
  }

  /// 设 tag（DD-23）。dsn null 时仅记内存快照（no-op 不发）；启用后同步推 Sentry scope。
  static void setTag(String key, String value) {
    _tags[key] = value;
    if (_enabled) {
      // ignore: discarded_futures
      Sentry.configureScope((scope) => scope.setTag(key, value));
    }
  }

  /// bootstrap 阶段 tag（DD-23）。
  static void tagBootstrap({String? stage, String? envelopeSource, String? decryptionFailure}) {
    if (stage != null) setTag(SentryTagKeys.bootstrapStage, stage);
    if (envelopeSource != null) setTag(SentryTagKeys.envelopeSource, envelopeSource);
    if (decryptionFailure != null) {
      setTag(SentryTagKeys.decryptionFailure, decryptionFailure);
    }
  }

  /// endpoint 阶段 tag（DD-23）。
  static void tagEndpoint({String? current, int? raceAttempts}) {
    if (current != null) setTag(SentryTagKeys.endpointCurrent, current);
    if (raceAttempts != null) {
      setTag(SentryTagKeys.endpointRaceAttempts, '$raceAttempts');
    }
  }

  /// 登录态 tag（DD-23 auth.state）。值取 `AuthState.name`（unauthenticated/authenticating/authenticated）。
  static void tagAuthState(String state) => setTag(SentryTagKeys.authState, state);

  /// 连通性 tag（DD-23 connectivity.online）。W5.4 connectivity provider 接入后由其调用。
  static void tagConnectivity({required bool online}) =>
      setTag(SentryTagKeys.connectivityOnline, online ? 'true' : 'false');

  /// flavor tag（DD-23 flavor.id）。bootstrap step 1 绑定 flavor 后调用。
  static void tagFlavor(String flavorId) =>
      setTag(SentryTagKeys.flavorId, flavorId);

  /// SDK 日志桥接（String 翻译，避免 import SDK LogLevel，第 4 轮 Property 2）。
  /// warning/error/fatal → Sentry.captureMessage（debug/info 丢弃，减噪）。
  static void captureFromSdk(String levelStr, String message) {
    if (!_enabled) return;
    final level = switch (levelStr) {
      'fatal' => SentryLevel.fatal,
      'error' => SentryLevel.error,
      'warning' => SentryLevel.warning,
      _ => null, // debug / info 不上报
    };
    if (level == null) return;
    // ignore: discarded_futures
    Sentry.captureMessage(message, level: level);
  }

  /// 用户 opt-out（κ-4）：关闭上报。重新启用需重启 app 重新 init（v0.1 简化）。
  static Future<void> setUserOptOut(bool optedOut) async {
    if (optedOut) {
      _enabled = false;
      await Sentry.close();
    } else if (_dsn != null && _dsn!.isNotEmpty) {
      _enabled = true;
    }
  }

  /// 测试重置。
  static void resetForTest() {
    _dsn = null;
    _enabled = false;
    _tags.clear();
  }
}
