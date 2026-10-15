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
library;

import 'dart:async';

import 'package:flutter/foundation.dart'
    show
        FlutterError,
        FlutterErrorDetails,
        FlutterExceptionHandler,
        kIsWeb,
        visibleForTesting;
import 'package:sentry_flutter/sentry_flutter.dart';

import 'sentry_sanitizer.dart';

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
const List<String> kSensitiveKeys = SentrySanitizer.sensitiveKeys;

/// Narrow SDK boundary, allowing tests to exercise configuration without native
/// initialization, background sessions or a real network transport.
@visibleForTesting
abstract interface class SentryBootstrapRuntime {
  Future<void> initialize(void Function(SentryFlutterOptions) configure);
  Future<void> close();
  Future<void> configureScope(void Function(Scope) configure);
  Future<void> captureException(
    Object error, {
    StackTrace? stackTrace,
    String? where,
    String? message,
    SentryLevel? level,
  });
  Future<void> captureMessage(String message, SentryLevel level);
}

/// Saved preference is durable, but this process cannot confirm that every
/// native crash handler stopped. A fresh process must apply the saved choice.
class SentryRestartRequiredException implements Exception {
  const SentryRestartRequiredException();

  @override
  String toString() =>
      'Restart the application to apply crash reporting changes.';
}

@visibleForTesting
abstract interface class SentryBootstrapRuntimePolicy {
  bool get preferenceChangesRequireRestart;
}

class _SdkRuntime
    implements SentryBootstrapRuntime, SentryBootstrapRuntimePolicy {
  const _SdkRuntime();

  // Native integration shutdown can swallow errors and some crash handlers
  // survive sentry_close(). Never use a successful Future as proof of shutdown.
  @override
  bool get preferenceChangesRequireRestart => !kIsWeb;

  @override
  Future<void> initialize(void Function(SentryFlutterOptions) configure) async {
    SentryFlutterOptions? configured;
    await SentryFlutter.init((options) {
      configured = options;
      configure(options);
    });
    if (!Sentry.isEnabled) {
      throw StateError('Sentry Dart initialization did not complete.');
    }
    final options = configured;
    if (options != null &&
        options.platform.supportsNativeIntegration &&
        options.autoInitializeNativeSdk &&
        !options.sdk.integrations.contains('nativeSdkIntegration')) {
      throw StateError(
        'Sentry native integration did not complete installation.',
      );
    }
    // The marker is necessary, not proof of native capture: native safe-call
    // helpers may log and swallow failures before the marker is registered.
  }

  @override
  Future<void> close() => Sentry.close();

  @override
  Future<void> configureScope(void Function(Scope) configure) async {
    await Sentry.configureScope(configure);
  }

  @override
  Future<void> captureException(
    Object error, {
    StackTrace? stackTrace,
    String? where,
    String? message,
    SentryLevel? level,
  }) async {
    await Sentry.captureEvent(
      SentryEvent(
        throwable: error,
        message: message == null ? null : SentryMessage(message),
        level: level,
      ),
      stackTrace: stackTrace,
      withScope: where == null
          ? null
          : (scope) => scope.setTag('swallowed.where', where),
    );
  }

  @override
  Future<void> captureMessage(String message, SentryLevel level) async {
    await Sentry.captureMessage(message, level: level);
  }
}

class _SentryConfiguration {
  const _SentryConfiguration({
    required this.dsn,
    required this.release,
    required this.environment,
    required this.sendDefaultPii,
    required this.tracesSampleRate,
  });

  final String dsn;
  final String release;
  final String? environment;
  final bool sendDefaultPii;
  final double tracesSampleRate;
}

/// Sentry 装配（纯逻辑 + 装配；dsn null 全 no-op）。
class SentryBootstrap {
  SentryBootstrap._();

  static bool _enabled = false;
  static bool _initialized = false;
  static bool _restartRequired = false;
  static bool _userOptedOut = false;
  static _SentryConfiguration? _configuration;
  static SentryBootstrapRuntime _runtime = const _SdkRuntime();
  static Future<void> _pending = Future.value();
  static FlutterExceptionHandler? _wrapper;
  static FlutterExceptionHandler? _chainedHandler;
  static FlutterExceptionHandler? _sdkHandler;
  static final Map<String, String> _tags = {};

  /// Whether application capture is allowed now; this is separate from the
  /// saved preference and cannot prove that native crash handlers are stopped.
  static bool get isEnabled => _enabled;

  /// Sticky for this process. Only a fresh process can apply a native change.
  static bool get restartRequired => _restartRequired;

  @visibleForTesting
  static bool get preferenceChangesRequireRestart =>
      _runtime is SentryBootstrapRuntimePolicy &&
      (_runtime as SentryBootstrapRuntimePolicy)
          .preferenceChangesRequireRestart;

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
  }) => _serialize(() async {
    if (_restartRequired) throw const SentryRestartRequiredException();
    await _stop();
    _userOptedOut = userOptedOut;
    _configuration = dsn == null || dsn.trim().isEmpty
        ? null
        : _SentryConfiguration(
            dsn: dsn,
            release: release,
            environment: environment,
            sendDefaultPii: sendDefaultPii,
            tracesSampleRate: tracesSampleRate,
          );
    if (!userOptedOut) await _start();
  });

  static Future<void> _serialize(Future<void> Function() operation) {
    final next = _pending.then((_) => operation());
    _pending = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  static Future<void> _start() async {
    final configuration = _configuration;
    if (_initialized) {
      if (_enabled) return;
      throw StateError('Sentry shutdown did not complete; retry or restart.');
    }
    if (configuration == null) return;
    try {
      await _runtime.initialize((options) {
        options.dsn = configuration.dsn;
        options.release = configuration.release;
        if (configuration.environment?.isNotEmpty ?? false) {
          options.environment = configuration.environment;
        }
        options.sendDefaultPii = configuration.sendDefaultPii;
        options.tracesSampleRate = configuration.tracesSampleRate;
        options.attachScreenshot = false;
        // Keep the supported privacy default explicit with the pinned SDK.
        // ignore: experimental_member_use
        options.attachViewHierarchy = false;
        // Native crash envelopes bypass Dart callbacks. Avoid automatically
        // recording native UI/console text; native crash stacks remain enabled.
        options.enableAutoNativeBreadcrumbs = false;
        SentryEvent? filterEvent(SentryEvent event, Hint hint) {
          try {
            return SentrySanitizer.scrubEvent(event);
          } catch (_) {
            // The SDK keeps the original event if a callback throws. Drop it
            // instead when filtering fails, so privacy does not fail open.
            return null;
          }
        }

        options.beforeSend = filterEvent;
        options.beforeSendFeedback = filterEvent;
        options.beforeBreadcrumb = (breadcrumb, hint) {
          if (breadcrumb == null) return null;
          try {
            return SentrySanitizer.scrubBreadcrumb(breadcrumb);
          } catch (_) {
            return null;
          }
        };
      });
      _sdkHandler = FlutterError.onError;
      _initialized = true;
      await _runtime.configureScope((scope) => _tags.forEach(scope.setTag));
      _enabled = true;
    } catch (_) {
      _enabled = false;
      // init can fail after installing integrations; clean them up before a
      // later attempt rather than leaving half an SDK running.
      _initialized = true;
      final needsRestart = preferenceChangesRequireRestart;
      if (needsRestart) _restartRequired = true;
      await _stop();
      if (needsRestart) throw const SentryRestartRequiredException();
      rethrow;
    }
  }

  static Future<void> _stop() async {
    _enabled = false;
    if (identical(FlutterError.onError, _wrapper) && _wrapper != null) {
      FlutterError.onError = _chainedHandler;
    }
    _wrapper = null;
    _chainedHandler = null;
    if (!_initialized) return;
    final current = FlutterError.onError;
    final preserveCurrent = !identical(current, _sdkHandler);
    try {
      await _runtime.close();
      _initialized = false;
      _sdkHandler = null;
    } catch (_) {
      // Sentry.close swaps to NoOpHub before teardown. A second successful
      // close may therefore be empty work; only restarting clears this lock.
      _restartRequired = true;
      throw const SentryRestartRequiredException();
    } finally {
      // SDK integration teardown restores its original handler; keep a newer
      // FlClash handler if attach() replaced it after initialization.
      if (preserveCurrent) FlutterError.onError = current;
    }
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
    if ((_wrapper != null && identical(flclashHandler, _wrapper)) ||
        (_sdkHandler != null && identical(flclashHandler, _sdkHandler))) {
      return;
    }
    _chainedHandler = flclashHandler;
    _wrapper = (FlutterErrorDetails details) {
      captureException(details.exception, stackTrace: details.stack);
      flclashHandler?.call(details);
    };
    FlutterError.onError = _wrapper;
  }

  /// 上报「永不抛」层吞掉的异常（#2：bootstrap / 反腐层吞前尽力上报，避免静默失败盲飞）。
  /// dsn 空 → no-op。[where] 作 tag `swallowed.where`，便于在 Sentry 按吞咽点聚合。
  static void captureException(
    Object error, {
    StackTrace? stackTrace,
    String? where,
  }) {
    if (!_enabled) return;
    _bestEffort(
      () => _runtime.captureException(
        error,
        stackTrace: stackTrace,
        where: where,
      ),
    );
  }

  /// beforeSend 脱敏：递归把敏感字段值替换为 '***'（κ-4 / § C）。
  /// 返回脱敏后的 map（纯函数，便于单测）。
  static Map<String, dynamic> scrubData(Map<String, dynamic> data) =>
      SentrySanitizer.scrubData(data);

  /// 设 tag（DD-23）。dsn null 时仅记内存快照（no-op 不发）；启用后同步推 Sentry scope。
  static void setTag(String key, String value) {
    // Scope tags can also be synchronized to native SDKs, outside beforeSend.
    final safeValue = SentrySanitizer.isSensitiveKey(key)
        ? SentrySanitizer.redacted
        : SentrySanitizer.scrubText(value);
    _tags[key] = safeValue;
    if (_enabled) {
      _bestEffort(
        () => _runtime.configureScope((scope) => scope.setTag(key, safeValue)),
      );
    }
  }

  /// bootstrap 阶段 tag（DD-23）。
  static void tagBootstrap({
    String? stage,
    String? envelopeSource,
    String? decryptionFailure,
  }) {
    if (stage != null) setTag(SentryTagKeys.bootstrapStage, stage);
    if (envelopeSource != null) {
      setTag(SentryTagKeys.envelopeSource, envelopeSource);
    }
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
  static void tagAuthState(String state) =>
      setTag(SentryTagKeys.authState, state);

  /// 连通性 tag（DD-23 connectivity.online）。W5.4 connectivity provider 接入后由其调用。
  static void tagConnectivity({required bool online}) =>
      setTag(SentryTagKeys.connectivityOnline, online ? 'true' : 'false');

  /// flavor tag（DD-23 flavor.id）。bootstrap step 1 绑定 flavor 后调用。
  static void tagFlavor(String flavorId) =>
      setTag(SentryTagKeys.flavorId, flavorId);

  /// SDK 日志桥接（String 翻译，避免 import SDK LogLevel，第 4 轮 Property 2）。
  /// warning/error/fatal → Sentry.captureMessage（debug/info 丢弃，减噪）。
  static void captureFromSdk(
    String levelStr,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (!_enabled) return;
    final level = switch (levelStr) {
      'fatal' => SentryLevel.fatal,
      'error' => SentryLevel.error,
      'warning' => SentryLevel.warning,
      _ => null, // debug / info 不上报
    };
    if (level == null) return;
    if (error != null) {
      _bestEffort(
        () => _runtime.captureException(
          error,
          stackTrace: stackTrace,
          message: message,
          level: level,
        ),
      );
    } else {
      _bestEffort(() => _runtime.captureMessage(message, level));
    }
  }

  static void _bestEffort(Future<void> Function() operation) {
    try {
      unawaited(
        operation().then<void>(
          (_) {},
          // Reporting its own delivery error can cause an endless capture loop.
          onError: (Object _, StackTrace _) {},
        ),
      );
    } catch (_) {
      // A synchronous SDK boundary failure must not affect application logic.
    }
  }

  /// Apply the saved preference. Native platforms require a fresh process;
  /// SDK shutdown cannot prove that every native crash handler was removed.
  static Future<void> setUserOptOut(bool optedOut) {
    if (optedOut ||
        (preferenceChangesRequireRestart && _userOptedOut != optedOut)) {
      _enabled = false;
    }
    return _serialize(() async {
      if (_restartRequired) throw const SentryRestartRequiredException();
      final changed = _userOptedOut != optedOut;
      _userOptedOut = optedOut;
      if (changed && preferenceChangesRequireRestart) {
        _restartRequired = true;
        await _stop();
        throw const SentryRestartRequiredException();
      }
      if (optedOut) {
        await _stop();
      } else {
        await _start();
      }
    });
  }

  @visibleForTesting
  static void setRuntimeForTest(SentryBootstrapRuntime runtime) {
    assert(!_initialized);
    _runtime = runtime;
  }

  /// 测试重置。
  static void resetForTest() {
    if (_wrapper != null && identical(FlutterError.onError, _wrapper)) {
      FlutterError.onError = _chainedHandler;
    }
    _configuration = null;
    _enabled = false;
    _initialized = false;
    _restartRequired = false;
    _userOptedOut = false;
    _runtime = const _SdkRuntime();
    _pending = Future.value();
    _wrapper = null;
    _chainedHandler = null;
    _sdkHandler = null;
    _tags.clear();
  }
}
