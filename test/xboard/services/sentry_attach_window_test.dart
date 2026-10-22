import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/bootstrap.dart';
import 'package:fl_clash/xboard/services/sentry_bootstrap.dart';
import 'package:fl_clash/xboard/xboard_module.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FlutterExceptionHandler? originalHandler;
  late _RecordingRuntime runtime;

  setUp(() {
    originalHandler = FlutterError.onError;
    SentryBootstrap.resetForTest();
    runtime = _RecordingRuntime();
    SentryBootstrap.setRuntimeForTest(runtime);
  });
  tearDown(() async {
    await SentryBootstrap.setUserOptOut(true);
    SentryBootstrap.resetForTest();
    FlutterError.onError = originalHandler;
    globalState.isAttach = false;
  });

  test(
    'early Sentry handler survives bootstrap attach before tray/core work',
    () async {
      await SentryBootstrap.installEarly(
        dsn: 'https://public@sentry.invalid/1',
        release: 'controlled@1+1',
      );
      final container = ProviderContainer(
        overrides: [systemActionProvider.overrideWith(_StopBeforeTray.new)],
      );
      addTearDown(container.dispose);
      globalState.container = container;
      globalState.isAttach = false;

      // Stop at the first action lookup so no real tray, profile, core, consent
      // dialog or network code can run. Bootstrap must retain the handler installed before native initialization.
      final installedHandler = FlutterError.onError;
      await expectLater(bootstrap.attach(), throwsStateError);
      expect(FlutterError.onError, same(installedHandler));
      expect(container.read(initProvider), isFalse);
      final error = StateError('Flutter framework error during early attach');
      final stack = StackTrace.current;
      FlutterError.onError!(
        FlutterErrorDetails(exception: error, stack: stack),
      );
      expect(runtime.errors, [error]);
      expect(runtime.stacks, [stack]);
      expect(globalState.isAttach, isFalse);
      SentryBootstrap.rechainFlutterError();
      FlutterError.onError!(
        FlutterErrorDetails(exception: error, stack: stack),
      );
      expect(runtime.errors, [error, error], reason: 'no duplicate wrapper');
    },
  );

  test(
    'outer startup catch forwards the original error and stack safely',
    () async {
      await SentryBootstrap.installEarly(
        dsn: 'https://public@sentry.invalid/1',
        release: 'controlled@1+1',
      );
      final error = StateError('native/core initialization failed');
      final stack = StackTrace.current;
      XboardModule.captureStartupFailure('main initialization', error, stack);
      expect(runtime.errors, [error]);
      expect(runtime.stacks, [stack]);
      expect(runtime.locations, ['main initialization']);
      runtime.failCapture = true;
      expect(
        () => XboardModule.captureStartupFailure(
          'main initialization',
          error,
          stack,
        ),
        returnsNormally,
      );
      await pumpEventQueue();
    },
  );
}

class _StopBeforeTray extends SystemAction {
  @override
  void build() {}

  @override
  Future<void> updateTray() =>
      throw StateError('controlled stop before tray/core work');
}

class _RecordingRuntime implements SentryBootstrapRuntime {
  final errors = <Object>[];
  final stacks = <StackTrace?>[];
  final locations = <String?>[];
  bool failCapture = false;

  @override
  Future<void> initialize(void Function(SentryFlutterOptions) configure) async {
    configure(SentryFlutterOptions());
    // The real SentryFlutter runtime installs its integration here. The
    // v0.9.1 Bootstrap must preserve it instead of assigning another handler.
    FlutterError.onError = (details) {
      errors.add(details.exception);
      stacks.add(details.stack);
      locations.add('framework');
    };
  }

  @override
  Future<void> close() async {}
  @override
  Future<void> configureScope(void Function(Scope) configure) async {
    configure(Scope(SentryOptions()));
  }

  @override
  Future<void> captureException(
    Object error, {
    StackTrace? stackTrace,
    String? where,
    String? message,
    SentryLevel? level,
  }) async {
    if (failCapture) throw StateError('controlled reporting failure');
    errors.add(error);
    stacks.add(stackTrace);
    locations.add(where);
  }

  @override
  Future<void> captureMessage(String message, SentryLevel level) async {}
}
