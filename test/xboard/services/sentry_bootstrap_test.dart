/// SentryBootstrap：dsn null no-op、原始诊断、8 类 tag 与 opt-out。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:fl_clash/xboard/services/sentry_bootstrap.dart';

void main() {
  late FakeSentryRuntime runtime;
  FlutterExceptionHandler? originalHandler;

  setUp(() {
    originalHandler = FlutterError.onError;
    SentryBootstrap.resetForTest();
    runtime = FakeSentryRuntime();
    SentryBootstrap.setRuntimeForTest(runtime);
  });
  tearDown(() async {
    runtime.failClose = false;
    if (!SentryBootstrap.restartRequired) {
      await SentryBootstrap.setUserOptOut(true);
    }
    SentryBootstrap.resetForTest();
    FlutterError.onError = originalHandler;
  });

  group('installEarly no-op', () {
    test('dsn null → 不启用', () async {
      await SentryBootstrap.installEarly(dsn: null, release: '1.0');
      expect(SentryBootstrap.isEnabled, isFalse);
      expect(runtime.initializations, 0);
    });
    test('dsn 空串 → 不启用', () async {
      await SentryBootstrap.installEarly(dsn: '', release: '1.0');
      expect(SentryBootstrap.isEnabled, isFalse);
      expect(runtime.initializations, 0);
    });
    test('dsn 非空 + 未 opt-out → 启用', () async {
      await SentryBootstrap.installEarly(
        dsn: 'https://x@sentry.io/1',
        release: '1.0',
      );
      expect(SentryBootstrap.isEnabled, isTrue);
      expect(runtime.initializations, 1);
      expect(runtime.options!.beforeSend, isNull);
      expect(runtime.options!.beforeSendFeedback, isNull);
      expect(runtime.options!.beforeBreadcrumb, isNull);
      expect(runtime.options!.sendDefaultPii, isFalse);
      expect(runtime.options!.tracesSampleRate, 0.0);
      expect(runtime.options!.enableLogs, isFalse);
      expect(runtime.options!.replay.sessionSampleRate, isNull);
      expect(runtime.options!.replay.onErrorSampleRate, isNull);
      expect(runtime.options!.replay.networkDetailAllowUrls, isEmpty);
      expect(runtime.options!.attachScreenshot, isFalse);
      // ignore: experimental_member_use
      expect(runtime.options!.attachViewHierarchy, isFalse);
      expect(runtime.options!.enableAutoNativeBreadcrumbs, isTrue);
      expect(runtime.options!.enableNativeCrashHandling, isTrue);
    });
    test('dsn 非空但 userOptedOut → 不启用（κ-4）', () async {
      await SentryBootstrap.installEarly(
        dsn: 'https://x@sentry.io/1',
        release: '1.0',
        userOptedOut: true,
      );
      expect(SentryBootstrap.isEnabled, isFalse);
      expect(runtime.initializations, 0);
    });
  });

  group('application startup once before core initialization', () {
    test(
      'pending saved choice blocks initialization and concurrent duplicate calls',
      () async {
        final choice = Completer<bool>();
        var reads = 0;
        Future<bool> readEnabled() {
          reads++;
          return choice.future;
        }

        final early = SentryBootstrap.installForApplicationStartup(
          dsn: 'https://public@sentry.invalid/1',
          release: '1',
          readEnabled: readEnabled,
        );
        final duplicate = SentryBootstrap.installForApplicationStartup(
          dsn: 'https://public@sentry.invalid/1',
          release: '1',
          readEnabled: readEnabled,
        );
        await pumpEventQueue();
        expect(reads, 1);
        expect(runtime.initializations, 0);
        choice.complete(true);
        await Future.wait([early, duplicate]);
        expect(runtime.initializations, 1);
        expect(runtime.closes, 0);
      },
    );
    test(
      'a repeated startup entry cannot undo a native restart requirement',
      () async {
        final nativeRuntime = _RestartPolicyRuntime();
        SentryBootstrap.setRuntimeForTest(nativeRuntime);
        Future<void> install() => SentryBootstrap.installForApplicationStartup(
          dsn: 'https://public@sentry.invalid/1',
          release: '1',
          readEnabled: () async => true,
        );
        await install();
        await expectLater(
          SentryBootstrap.setUserOptOut(true),
          throwsA(isA<SentryRestartRequiredException>()),
        );
        await install();
        expect(nativeRuntime.initializations, 1);
        expect(nativeRuntime.closes, 1);
        expect(SentryBootstrap.restartRequired, isTrue);
        expect(SentryBootstrap.isEnabled, isFalse);
      },
    );
  });

  group('DD-23 8 类 tag', () {
    test('tag 原值写入快照及 SDK scope，保留完整 URL 和字段', () async {
      const endpoint =
          'https://user:pass@example.com/api?custom=secret#details';
      SentryBootstrap.tagEndpoint(current: endpoint);
      SentryBootstrap.setTag('api_token', 'synthetic-before-init');
      await SentryBootstrap.installEarly(
        dsn: 'https://x@sentry.invalid/1',
        release: '1',
      );
      expect(runtime.scope.tags[SentryTagKeys.endpointCurrent], endpoint);
      expect(runtime.scope.tags['api_token'], 'synthetic-before-init');
      SentryBootstrap.setTag(
        'api_token',
        'Bearer synthetic-after-init test@example.com',
      );
      expect(
        runtime.scope.tags['api_token'],
        'Bearer synthetic-after-init test@example.com',
      );
      expect(
        SentryBootstrap.tagsSnapshot[SentryTagKeys.endpointCurrent],
        endpoint,
      );
    });
    test('tagBootstrap stage/source/failure', () {
      SentryBootstrap.tagBootstrap(
        stage: 'async',
        envelopeSource: 'cache',
        decryptionFailure: 'tagError',
      );
      final t = SentryBootstrap.tagsSnapshot;
      expect(t[SentryTagKeys.bootstrapStage], 'async');
      expect(t[SentryTagKeys.envelopeSource], 'cache');
      expect(t[SentryTagKeys.decryptionFailure], 'tagError');
    });
    test('tagEndpoint current/raceAttempts', () {
      SentryBootstrap.tagEndpoint(current: 'https://api', raceAttempts: 3);
      final t = SentryBootstrap.tagsSnapshot;
      expect(t[SentryTagKeys.endpointCurrent], 'https://api');
      expect(t[SentryTagKeys.endpointRaceAttempts], '3');
    });
  });

  group('opt-out（κ-4）', () {
    test('setUserOptOut(true) → 关闭', () async {
      await SentryBootstrap.installEarly(
        dsn: 'https://x@sentry.io/1',
        release: '1.0',
      );
      await SentryBootstrap.setUserOptOut(true);
      expect(SentryBootstrap.isEnabled, isFalse);
      expect(runtime.closes, 1);
    });
    test('setUserOptOut(false) 后恢复（dsn 仍在）', () async {
      await SentryBootstrap.installEarly(
        dsn: 'https://x@sentry.io/1',
        release: '1.0',
      );
      await SentryBootstrap.setUserOptOut(true);
      await SentryBootstrap.setUserOptOut(false);
      expect(SentryBootstrap.isEnabled, isTrue);
      expect(runtime.initializations, 2);
      expect(runtime.options!.release, '1.0');
    });
    test('启动关闭后在同一会话启用，恢复配置和 tag', () async {
      SentryBootstrap.tagFlavor('brand_a');
      await SentryBootstrap.installEarly(
        dsn: 'https://x@sentry.invalid/1',
        release: 'brand_a@1.0+1',
        environment: 'brand_a',
        userOptedOut: true,
      );
      await SentryBootstrap.setUserOptOut(false);
      expect(runtime.initializations, 1);
      expect(runtime.options!.environment, 'brand_a');
      expect(runtime.scope.tags[SentryTagKeys.flavorId], 'brand_a');
    });
    test('重复开启/关闭幂等，不重新初始化已启用的 SDK', () async {
      await SentryBootstrap.installEarly(
        dsn: 'https://x@sentry.invalid/1',
        release: '1',
      );
      await SentryBootstrap.setUserOptOut(false);
      expect(runtime.initializations, 1);
      await SentryBootstrap.setUserOptOut(true);
      await SentryBootstrap.setUserOptOut(true);
      expect(runtime.closes, 1);
    });
    test('缺少 DSN 不能开启', () async {
      await SentryBootstrap.installEarly(dsn: null, release: '1');
      await SentryBootstrap.setUserOptOut(false);
      expect(SentryBootstrap.isEnabled, isFalse);
      expect(runtime.initializations, 0);
    });
    test('初始化失败不伪装成功，可在失败清理后重试', () async {
      runtime.failInitialize = true;
      await expectLater(
        SentryBootstrap.installEarly(
          dsn: 'https://x@sentry.invalid/1',
          release: '1',
        ),
        throwsStateError,
      );
      expect(SentryBootstrap.isEnabled, isFalse);
      expect(runtime.closes, 1);
      runtime.failInitialize = false;
      await SentryBootstrap.setUserOptOut(false);
      expect(SentryBootstrap.isEnabled, isTrue);
    });
    test('关闭失败永久锁定本进程，二次空关闭不能伪装恢复', () async {
      await SentryBootstrap.installEarly(
        dsn: 'https://x@sentry.invalid/1',
        release: '1',
      );
      runtime.failClose = true;
      final needsRestart = throwsA(isA<SentryRestartRequiredException>());
      await expectLater(SentryBootstrap.setUserOptOut(true), needsRestart);
      expect(SentryBootstrap.isEnabled, isFalse);
      expect(SentryBootstrap.restartRequired, isTrue);
      await expectLater(SentryBootstrap.setUserOptOut(false), needsRestart);
      expect(runtime.initializations, 1);
      runtime.failClose = false;
      await expectLater(SentryBootstrap.setUserOptOut(true), needsRestart);
      expect(runtime.closes, 1);
      expect(SentryBootstrap.isEnabled, isFalse);
    });
    test('并发关闭/开启按顺序执行，不遗留关闭的伪启用 SDK', () async {
      await SentryBootstrap.installEarly(
        dsn: 'https://x@sentry.invalid/1',
        release: '1',
      );
      await Future.wait([
        SentryBootstrap.setUserOptOut(true),
        SentryBootstrap.setUserOptOut(false),
      ]);
      expect(runtime.closes, 1);
      expect(runtime.initializations, 2);
      expect(SentryBootstrap.isEnabled, isTrue);
    });
  });

  group('生产原生偏好重启策略（无原生初始化或网络）', () {
    test('原生初始化部分失败后，即使cleanup正常也需重启', () async {
      final nativeRuntime = _RestartPolicyRuntime()..failInitialize = true;
      SentryBootstrap.setRuntimeForTest(nativeRuntime);
      await expectLater(
        SentryBootstrap.installEarly(
          dsn: 'https://x@sentry.invalid/1',
          release: '1',
        ),
        throwsA(isA<SentryRestartRequiredException>()),
      );
      expect(nativeRuntime.closes, 1);
      expect(SentryBootstrap.restartRequired, isTrue);
      expect(SentryBootstrap.isEnabled, isFalse);
      nativeRuntime.failInitialize = false;
      await expectLater(
        SentryBootstrap.setUserOptOut(false),
        throwsA(isA<SentryRestartRequiredException>()),
      );
      expect(nativeRuntime.initializations, 1);
    });
    test('真实生产runtime从关闭启动后开启，要求下次进程初始化', () async {
      SentryBootstrap.resetForTest(); // Restore the actual production runtime.
      expect(SentryBootstrap.preferenceChangesRequireRestart, isTrue);
      await SentryBootstrap.installEarly(
        dsn: 'https://x@sentry.invalid/1',
        release: '1',
        userOptedOut: true,
      ); // Opted out: SentryFlutter.init is never invoked.
      await expectLater(
        SentryBootstrap.setUserOptOut(false),
        throwsA(isA<SentryRestartRequiredException>()),
      );
      expect(SentryBootstrap.isEnabled, isFalse);
      expect(SentryBootstrap.restartRequired, isTrue);
    });

    test('原生close吞错并正常返回也只能标记待重启，重复NoOp不能解锁', () async {
      final nativeRuntime = _RestartPolicyRuntime();
      SentryBootstrap.setRuntimeForTest(nativeRuntime);
      await SentryBootstrap.installEarly(
        dsn: 'https://x@sentry.invalid/1',
        release: '1',
      );
      expect(SentryBootstrap.isEnabled, isTrue);
      expect(SentryBootstrap.restartRequired, isFalse);
      final stopping = SentryBootstrap.setUserOptOut(true);
      expect(SentryBootstrap.isEnabled, isFalse, reason: '同步停止业务capture');
      final needsRestart = throwsA(isA<SentryRestartRequiredException>());
      await expectLater(stopping, needsRestart);
      expect(nativeRuntime.closes, 1);
      expect(SentryBootstrap.restartRequired, isTrue);
      await expectLater(SentryBootstrap.setUserOptOut(true), needsRestart);
      await expectLater(SentryBootstrap.setUserOptOut(false), needsRestart);
      await expectLater(
        SentryBootstrap.installEarly(
          dsn: 'https://x@sentry.invalid/1',
          release: '1',
        ),
        needsRestart,
      );
      expect(nativeRuntime.closes, 1);
      expect(nativeRuntime.initializations, 1);
      expect(SentryBootstrap.isEnabled, isFalse);
    });

    test('原生启动未初始化时，开启偏好也不在当前进程启动SDK', () async {
      final nativeRuntime = _RestartPolicyRuntime();
      SentryBootstrap.setRuntimeForTest(nativeRuntime);
      await SentryBootstrap.installEarly(
        dsn: 'https://x@sentry.invalid/1',
        release: '1',
        userOptedOut: true,
      );
      await expectLater(
        SentryBootstrap.setUserOptOut(false),
        throwsA(isA<SentryRestartRequiredException>()),
      );
      expect(nativeRuntime.initializations, 0);
      expect(nativeRuntime.closes, 0);
      expect(SentryBootstrap.restartRequired, isTrue);
    });

    test('没有改变已开启的偏好时，不关闭SDK也不要求重启', () async {
      final nativeRuntime = _RestartPolicyRuntime();
      SentryBootstrap.setRuntimeForTest(nativeRuntime);
      await SentryBootstrap.installEarly(
        dsn: 'https://x@sentry.invalid/1',
        release: '1',
      );
      await SentryBootstrap.setUserOptOut(false);
      expect(SentryBootstrap.isEnabled, isTrue);
      expect(SentryBootstrap.restartRequired, isFalse);
      expect(nativeRuntime.closes, 0);
      expect(nativeRuntime.initializations, 1);
      // Clean up the fake directly; the production policy intentionally cannot
      // be cleared by calling setUserOptOut in the same process.
      await nativeRuntime.close();
      SentryBootstrap.resetForTest();
      SentryBootstrap.setRuntimeForTest(runtime);
    });
  });

  group('FlutterError 链', () {
    test('重复重链只捕获一次，并保留底座处理器', () async {
      await SentryBootstrap.installEarly(
        dsn: 'https://x@sentry.invalid/1',
        release: '1',
      );
      var calls = 0;
      void baseHandler(FlutterErrorDetails details) => calls++;
      FlutterError.onError = baseHandler;
      SentryBootstrap.rechainFlutterError();
      SentryBootstrap.rechainFlutterError();
      final error = StateError('sample');
      final stack = StackTrace.current;
      FlutterError.onError!(
        FlutterErrorDetails(exception: error, stack: stack),
      );
      expect(calls, 1);
      expect(runtime.errors, hasLength(1));
      expect(runtime.errors.single.error, same(error));
      expect(runtime.errors.single.stackTrace, same(stack));
      await SentryBootstrap.setUserOptOut(true);
      expect(FlutterError.onError, same(baseHandler));
    });
    test('SDK 处理器未被覆盖时不添加重复捕获层', () async {
      await SentryBootstrap.installEarly(
        dsn: 'https://x@sentry.invalid/1',
        release: '1',
      );
      final sdkHandler = FlutterError.onError;
      SentryBootstrap.rechainFlutterError();
      expect(FlutterError.onError, same(sdkHandler));
    });
    test('底座后续再次覆盖，可针对新处理器重链', () async {
      await SentryBootstrap.installEarly(
        dsn: 'https://x@sentry.invalid/1',
        release: '1',
      );
      FlutterError.onError = (_) {};
      SentryBootstrap.rechainFlutterError();
      var latestCalls = 0;
      FlutterError.onError = (_) => latestCalls++;
      SentryBootstrap.rechainFlutterError();
      FlutterError.onError!(
        FlutterErrorDetails(exception: StateError('sample')),
      );
      expect(latestCalls, 1);
      expect(runtime.errors, hasLength(1));
    });
  });

  group('SDK bridge', () {
    test('reporter Future 失败被隔离，不产生新未捕获异常或上报循环', () async {
      await SentryBootstrap.installEarly(
        dsn: 'https://x@sentry.invalid/1',
        release: '1',
      );
      runtime.failReporting = true;
      SentryBootstrap.captureException(StateError('application error'));
      SentryBootstrap.captureFromSdk(
        'error',
        'SDK error',
        error: StateError('SDK'),
      );
      SentryBootstrap.captureFromSdk('warning', 'SDK warning');
      SentryBootstrap.setTag('stage', 'application');
      await pumpEventQueue();
      expect(runtime.reportingFailures, 4);
      expect(SentryBootstrap.isEnabled, isTrue);
    });
    test('保留原异常、堆栈、日志上下文与等级', () async {
      await SentryBootstrap.installEarly(
        dsn: 'https://x@sentry.invalid/1',
        release: '1',
      );
      final error = StateError('sdk failed Bearer synthetic-token');
      final stack = StackTrace.current;
      const message =
          'test@example.com uuid=123e4567-e89b-12d3-a456-426614174000 '
          'https://example.com/api?token=synthetic-token';
      SentryBootstrap.captureFromSdk(
        'error',
        message,
        error: error,
        stackTrace: stack,
      );
      expect(runtime.errors.single.error, same(error));
      expect(runtime.errors.single.stackTrace, same(stack));
      expect(runtime.errors.single.message, message);
      expect(runtime.errors.single.level, SentryLevel.error);
    });
    test('无异常对象时保留消息，debug/info 丢弃，关闭后不捕获', () async {
      await SentryBootstrap.installEarly(
        dsn: 'https://x@sentry.invalid/1',
        release: '1',
      );
      SentryBootstrap.captureFromSdk('warning', 'warning');
      SentryBootstrap.captureFromSdk('debug', 'debug');
      SentryBootstrap.captureFromSdk('info', 'info');
      expect(runtime.messages, ['warning']);
      await SentryBootstrap.setUserOptOut(true);
      SentryBootstrap.captureFromSdk('fatal', 'fatal');
      expect(runtime.messages, ['warning']);
    });
  });

  group('实际 SDK 事件序列化', () {
    test('未安装过滤器，事件、面包屑、身份字段和调试 ID 原值进入传输', () async {
      await SentryBootstrap.installEarly(
        dsn: 'https://x@sentry.invalid/1',
        release: '1',
      );
      const debugId = '123e4567-e89b-12d3-a456-426614174000';
      const message = 'Bearer synthetic-token email=test@example.com';
      final transport = RecordingTransport();
      final options = runtime.options!
        ..sendClientReports = false
        ..transport = transport;
      final client = SentryClient(options);
      addTearDown(client.close);
      await runtime.scope.addBreadcrumb(
        Breadcrumb(
          message: 'email=test@example.com',
          data: {'token': 'synthetic-token', 'uuid': debugId},
        ),
      );
      final event = SentryEvent.fromJson({
        'event_id': '12345678901234567890123456789012',
        'message': {'formatted': message},
        'user': {'id': debugId, 'email': 'test@example.com'},
        'request': {
          'url': 'https://example.com/api?token=synthetic-token',
          'headers': {'Authorization': 'Bearer synthetic-token'},
          'data': {'password': 'synthetic-password'},
        },
        'extra': {
          'data': [
            {'access_token': 'synthetic-token'},
          ],
        },
        'exception': {
          'values': [
            {
              'type': 'StateError',
              'value': message,
              'stacktrace': {
                'frames': [
                  {
                    'function': 'mtx_do_lock',
                    'filename': 'mutex.cpp',
                    'lineno': 103,
                    'vars': {'token': 'synthetic-token'},
                  },
                ],
              },
            },
          ],
        },
        'debug_meta': {
          'images': [
            {
              'type': 'pe',
              'debug_id': debugId,
              'code_id': '5f3759df1000',
              'image_addr': '0x10000000',
              'debug_file': 'deployment-check.pdb',
            },
          ],
        },
      });
      SentryBootstrap.setTag('api_token', 'synthetic-token');
      await client.captureEvent(event, scope: runtime.scope);
      final json = transport.events.single;
      expect(json['message']['formatted'], message);
      expect(json['user'], {'id': debugId, 'email': 'test@example.com'});
      expect(json['request'], event.toJson()['request']);
      expect(json['extra']['data'][0]['access_token'], 'synthetic-token');
      expect(json['tags']['api_token'], 'synthetic-token');
      expect(json['breadcrumbs'][0]['message'], 'email=test@example.com');
      expect(json['breadcrumbs'][0]['data'], {
        'token': 'synthetic-token',
        'uuid': debugId,
      });
      final exception = json['exception']['values'][0];
      expect(exception['value'], message);
      expect(exception['stacktrace']['frames'][0]['vars'], {
        'token': 'synthetic-token',
      });
      expect(json['debug_meta'], event.toJson()['debug_meta']);
    });
  });
}

class CapturedException {
  CapturedException(this.error, this.stackTrace, this.message, this.level);
  final Object error;
  final StackTrace? stackTrace;
  final String? message;
  final SentryLevel? level;
}

class FakeSentryRuntime implements SentryBootstrapRuntime {
  int initializations = 0;
  int closes = 0;
  bool failInitialize = false;
  bool failClose = false;
  bool failReporting = false;
  int reportingFailures = 0;
  SentryFlutterOptions? options;
  Scope scope = Scope(SentryOptions());
  FlutterExceptionHandler? _previousHandler;
  final errors = <CapturedException>[];
  final messages = <String>[];

  @override
  Future<void> initialize(void Function(SentryFlutterOptions) configure) async {
    initializations++;
    options = SentryFlutterOptions();
    configure(options!);
    scope = Scope(options!);
    if (failInitialize) throw StateError('controlled init failure');
    _previousHandler = FlutterError.onError;
    FlutterError.onError = (_) {};
  }

  @override
  Future<void> close() async {
    closes++;
    if (failClose) throw StateError('controlled close failure');
    FlutterError.onError = _previousHandler;
  }

  @override
  Future<void> configureScope(void Function(Scope) configure) async =>
      _configureScope(configure);

  void _configureScope(void Function(Scope) configure) {
    _checkReporting();
    configure(scope);
  }

  void _checkReporting() {
    if (failReporting) {
      reportingFailures++;
      throw StateError('controlled reporting failure');
    }
  }

  @override
  Future<void> captureException(
    Object error, {
    StackTrace? stackTrace,
    String? where,
    String? message,
    SentryLevel? level,
  }) async {
    _checkReporting();
    errors.add(CapturedException(error, stackTrace, message, level));
  }

  @override
  Future<void> captureMessage(String message, SentryLevel level) async {
    _checkReporting();
    messages.add(message);
  }
}

/// Serializes with the real SDK but never opens a transport connection.
class RecordingTransport implements Transport {
  final events = <Map<String, dynamic>>[];

  @override
  Future<SentryId?> send(SentryEnvelope envelope) async {
    for (final item in envelope.items) {
      if (item.header.type == 'event') {
        events.add(
          jsonDecode(utf8.decode(await item.dataFactory()))
              as Map<String, dynamic>,
        );
      }
    }
    return envelope.header.eventId;
  }
}

class _RestartPolicyRuntime extends FakeSentryRuntime
    implements SentryBootstrapRuntimePolicy {
  @override
  bool get preferenceChangesRequireRestart => true;
}
