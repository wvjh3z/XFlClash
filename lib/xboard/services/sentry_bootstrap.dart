/// Sentry crash 上报装配（NFR-7 / DD-14 链式 / DD-23 8 类 tag / κ-4 GDPR opt-out / 决策 #5）。
///
/// **不接管 FlutterError.onError**（决策 #5 / ξ-Sentry）：用基础 `Sentry.init`（非 `SentryFlutter.init`
/// 默认接管），链式 wrap 保留 FlClash 既有 handler（DD-14：先 Sentry 再调旧 handler 保 commonPrint.log）。
///
/// **§ C 配置（κ-4 GDPR）**：sendDefaultPii=false + tracesSampleRate=0 + beforeSend 过滤
/// token/password/email/uuid。`dsn==null`（dev / 用户 opt-out）全 no-op。
///
/// **DD-23 8 类 tag**：bootstrap.stage / envelope_source / decryption_failure / endpoint.current /
/// endpoint.race_attempts / auth.state / connectivity.online / flavor.id。
///
/// **实施期说明**：本类提供装配 + tag + beforeSend 过滤的**纯逻辑**（可单测）；真实 `Sentry.init`
/// 调用点在 [installEarly]，dsn==null 时不触达 sentry 包（测试默认 no-op 路径）。
library;

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
  /// 真实 `Sentry.init` 在此触发（仅 dsn 非空时）；本仓 headless 测试默认 dsn==null 走 no-op。
  static Future<void> installEarly({
    required String? dsn,
    required String release,
    bool sendDefaultPii = false, // κ-4 默认 false
    double tracesSampleRate = 0.0, // v0.1 = 0
    bool userOptedOut = false, // κ-4 opt-out（默认 ON → false）
  }) async {
    _dsn = dsn;
    _enabled = dsn != null && dsn.isNotEmpty && !userOptedOut;
    if (!_enabled) return; // no-op
    // 真实 Sentry.init 调用点（W8 真机/CI 接入；此处仅装配状态，避免 headless 触达 sentry 包）。
    // await Sentry.init((o) { o.dsn = dsn; o.release = release;
    //   o.sendDefaultPii = sendDefaultPii; o.tracesSampleRate = tracesSampleRate;
    //   o.beforeSend = (event, hint) => scrubEvent(event); });
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

  /// 设 tag（DD-23）。dsn null 时仅记内存快照（no-op 不发）。
  static void setTag(String key, String value) {
    _tags[key] = value;
    // if (_enabled) Sentry.configureScope((s) => s.setTag(key, value));
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

  /// SDK 日志桥接（String 翻译，避免 import SDK LogLevel，第 4 轮 Property 2）。
  static void captureFromSdk(String levelStr, String message) {
    if (!_enabled) return;
    // if (levelStr == 'error' || levelStr == 'fatal') Sentry.captureMessage(message, level: ...);
  }

  /// 用户 opt-out（κ-4）：关闭上报。
  static Future<void> setUserOptOut(bool optedOut) async {
    if (optedOut) {
      _enabled = false;
      // await Sentry.close();
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
