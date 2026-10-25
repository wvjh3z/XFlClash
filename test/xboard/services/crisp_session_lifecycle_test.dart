import 'dart:async';
import 'dart:io';

import 'package:crisp_chat/crisp_chat.dart';
import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/services/crisp_chat_driver.dart';
import 'package:fl_clash/xboard/services/crisp_support_service.dart';

class FakeDriver implements CrispChatDriver {
  final calls = <String>[];
  // Closed by each test tearDown.
  // ignore: close_sinks
  final events = StreamController<void>.broadcast();
  Completer<String?>? pendingId;
  Completer<void>? pendingWrite;
  bool failReset = false;
  bool failWrite = false;
  @override
  Stream<void> get sessionLoaded => events.stream;
  @override
  Future<void> open(CrispConfig config) async {
    calls.add('open');
  }

  @override
  Future<String?> sessionId() async =>
      pendingId == null ? 'session' : pendingId!.future;
  @override
  Future<void> setString(String key, String value) async {
    calls.add('write:$key');
    if (failWrite) throw StateError('write failed');
    await pendingWrite?.future;
  }

  @override
  Future<void> reset(String id) async {
    calls.add('reset');
    if (failReset) throw StateError('reset failed');
  }
}

class MockWindow extends Mock implements Webview {}

class MockPreferences extends Mock implements SharedPreferences {}

class DelayedPreferencesStore {
  DelayedPreferencesStore() {
    when(() => preferences.getBool(any())).thenAnswer((invocation) {
      return values['flutter.${invocation.positionalArguments.single}']
          as bool?;
    });
    when(() => preferences.remove(any())).thenAnswer((invocation) {
      return remove(invocation.positionalArguments.single as String);
    });
    when(() => preferences.setBool(any(), any())).thenAnswer((invocation) {
      return setValue(
        invocation.positionalArguments[0] as String,
        invocation.positionalArguments[1] as bool,
      );
    });
  }

  final preferences = MockPreferences();
  final values = <String, Object>{};
  final calls = <String>[];
  final removeStarted = Completer<void>();
  Completer<void>? pendingRemove;
  bool failSet = false;

  Future<bool> remove(String key) async {
    calls.add('remove');
    if (!removeStarted.isCompleted) removeStarted.complete();
    await pendingRemove?.future;
    values.remove('flutter.$key');
    return true;
  }

  Future<bool> setValue(String key, bool value) async {
    calls.add('set:$value');
    if (failSet) return false;
    values['flutter.$key'] = value;
    return true;
  }

  Future<Map<String, Object>> getAll() async => Map.from(values);
}

class DesktopWindowHarness {
  static final instances = <int, DesktopWindowHarness>{};
  final handle = instances.length + 1;
  OnUrlRequestCallback? navigate;
  final loadErrors = StreamController<WebviewLoadError>.broadcast();
  DesktopWindowHarness({bool autoClose = true}) {
    instances[handle] = this;
    when(() => window.nativeWindowHandle).thenReturn(handle);
    when(() => window.onLoadError).thenAnswer((_) => loadErrors.stream);
    when(() => window.setOnUrlRequestCallback(any())).thenAnswer((call) async {
      navigate = call.positionalArguments.first as OnUrlRequestCallback?;
    });
    when(() => window.onClose).thenAnswer((_) => closed.future);
    when(() => window.launch(any())).thenAnswer((invocation) async {
      page = invocation.positionalArguments.first as String;
    });
    when(() => window.close()).thenAnswer((_) async {
      closeCalls++;
      if (autoClose && !closed.isCompleted) closed.complete();
    });

    when(() => window.reload()).thenAnswer((_) async {
      reloadCalls++;
    });
    when(() => window.evaluateJavaScript(any())).thenAnswer((invocation) async {
      final script = invocation.positionalArguments.first as String;
      if (script.contains('__xbCrispBootstrap=false')) return 'ok';
      if (script.contains('__xbCrispBootstrap')) return bootstrapReply;
      if (script.contains('chat:show')) {
        revealCalls++;
        return 'ok';
      }
      if (script.contains('"session:data"')) {
        return pendingWrite == null ? writeReply : pendingWrite!.future;
      }
      return pendingSession == null ? sessionReply : pendingSession!.future;
    });
  }

  final window = MockWindow();
  final closed = Completer<void>();
  String? page;
  String? bootstrapReply = 'loaded';
  String? sessionReply = 'new-session';
  String? writeReply = 'ok';
  Completer<void>? pendingForeground;
  Completer<String?>? pendingSession;
  Completer<String?>? pendingWrite;
  int closeCalls = 0;
  int foregroundCalls = 0;
  int reloadCalls = 0;
  int revealCalls = 0;

  File get pageFile => File.fromUri(Uri.parse(page!));

  Future<void> waitForPageRemoval() async {
    final deadline = Stopwatch()..start();
    while (await pageFile.exists()) {
      if (deadline.elapsed > const Duration(seconds: 1)) {
        fail('temporary HTML was not deleted after native close');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  Future<void> dispose() async {
    await loadErrors.close();
    if (!closed.isCompleted) closed.complete();
    if (page != null) await waitForPageRemoval();
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  registerFallbackValue((String _) => false);
  binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('window'),
    (call) async {
      if (call.method != 'focusBorrowedWindow') {
        throw StateError('unexpected method');
      }
      final harness = DesktopWindowHarness.instances[call.arguments['handle']]!;
      harness.foregroundCalls++;
      await harness.pendingForeground?.future;
      return null;
    },
  );
  late FakeDriver driver;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    XboardConfig.bind(
      const XboardConfig(
        subscribeUserAgent: 'test',
        devApiEndpoint: 'https://test.invalid',
        devSubscriptionEndpoint: 'https://test.invalid',
        debug: false,
        kIsTest: true,
        crispWebsiteId: 'website-test',
      ),
    );
    driver = FakeDriver();
    await CrispSupportService.setDriverForTest(driver);
  });
  tearDown(() async {
    await driver.events.close();
    XboardConfig.resetForTest();
  });

  test('repeated opens share one operation', () async {
    driver.pendingId = Completer();
    final first = CrispSupportService.open();
    final second = CrispSupportService.open();
    expect(identical(first, second), isTrue);
    driver.pendingId!.complete('ready');
    expect(await first, isTrue);
    expect(driver.calls, ['open', 'write:Source']);
    expect(driver.events.hasListener, isFalse);
  });

  test(
    'reset during readiness invalidates old writes and precedes new open',
    () async {
      driver.pendingId = Completer();
      final first = CrispSupportService.open();
      await Future<void>.delayed(Duration.zero);
      final reset = CrispSupportService.reset();
      final second = CrispSupportService.open();
      driver.pendingId!.complete('old');
      expect(await first, isFalse);
      await reset;
      expect(await second, isTrue);
      expect(driver.calls, ['open', 'reset', 'open', 'write:Source']);
    },
  );

  test('in-flight write drains before reset and next identity', () async {
    driver.pendingWrite = Completer();
    final first = CrispSupportService.open();
    await Future<void>.delayed(Duration.zero);
    final reset = CrispSupportService.reset();
    expect(driver.calls, ['open', 'write:Source']);
    driver.pendingWrite!.complete();
    expect(await first, isFalse);
    await reset;
    expect(driver.calls.last, 'reset');
  });

  test('failed reset blocks next open until reset succeeds', () async {
    driver.failReset = true;
    await CrispSupportService.reset();
    expect(await CrispSupportService.open(), isFalse);
    expect(driver.calls, ['reset', 'reset']);
    driver.failReset = false;
    expect(await CrispSupportService.open(), isTrue);
    expect(driver.calls, ['reset', 'reset', 'reset', 'open', 'write:Source']);
  });

  test(
    'async metadata failure is reported and does not wedge future opens',
    () async {
      driver.failWrite = true;
      expect(await CrispSupportService.open(), isFalse);
      driver.failWrite = false;
      expect(await CrispSupportService.open(), isTrue);
    },
  );

  test('caller account revision change rejects late session result', () async {
    var current = true;
    driver.pendingId = Completer();
    final open = CrispSupportService.open(isCurrent: () => current);
    await Future<void>.delayed(Duration.zero);
    current = false;
    driver.pendingId!.complete('old');
    expect(await open, isFalse);
    expect(driver.calls, ['open']);
  });

  Matcher failure(CrispChatFailure value) => throwsA(
    isA<CrispChatException>().having(
      (error) => error.failure,
      'failure',
      value,
    ),
  );

  DesktopCrispChatDriver desktopFor(
    DesktopWindowHarness harness, {
    Duration ioTimeout = const Duration(milliseconds: 200),
    Duration startupTimeout = const Duration(milliseconds: 100),
    Duration closeTimeout = const Duration(milliseconds: 40),
    Future<SharedPreferences> Function()? preferences,
  }) => DesktopCrispChatDriver(
    isWindowsOverride: false,
    available: () async => true,
    create: (_) async => harness.window,
    ioTimeout: ioTimeout,
    startupTimeout: startupTimeout,
    closeTimeout: closeTimeout,
    preferences: preferences,
    bootstrapPollInterval: const Duration(milliseconds: 2),
  );

  test(
    'desktop unavailable is typed and never creates a visitor fallback',
    () async {
      var created = false;
      final desktop = DesktopCrispChatDriver(
        isWindowsOverride: false,
        available: () async => false,
        create: (_) async {
          created = true;
          return MockWindow();
        },
      );
      await expectLater(
        desktop.open(CrispConfig(websiteID: 'test')),
        failure(CrispChatFailure.webViewUnavailable),
      );
      expect(created, isFalse);
    },
  );

  test('Windows missing runtime has its own failure', () async {
    final desktop = DesktopCrispChatDriver(
      isWindowsOverride: true,
      available: () async => false,
    );
    await expectLater(
      desktop.open(CrispConfig(websiteID: 'test')),
      failure(CrispChatFailure.webView2Unavailable),
    );
  });

  test(
    'availability timeout is bounded and errors omit platform details',
    () async {
      final available = Completer<bool>();
      final desktop = DesktopCrispChatDriver(
        isWindowsOverride: false,
        available: () => available.future,
        ioTimeout: const Duration(milliseconds: 20),
      );
      await expectLater(
        desktop.open(CrispConfig(websiteID: 'test')),
        failure(CrispChatFailure.startupTimeout),
      );
      available.completeError(StateError('private-account/private-path'));
      expect(
        const CrispChatException(
          CrispChatFailure.webViewUnavailable,
        ).toString(),
        'CrispChatException(webViewUnavailable)',
      );
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'Windows availability check error does not report a missing runtime',
    () async {
      final desktop = DesktopCrispChatDriver(
        isWindowsOverride: true,
        available: () async => throw StateError('private-native-detail'),
      );
      await expectLater(
        desktop.open(CrispConfig(websiteID: 'test')),
        failure(CrispChatFailure.startupFailed),
      );
    },
  );

  test('empty website is rejected before I/O', () async {
    var checked = false;
    final desktop = DesktopCrispChatDriver(
      available: () async {
        checked = true;
        return true;
      },
    );
    await expectLater(
      desktop.open(CrispConfig(websiteID: ' ')),
      failure(CrispChatFailure.notConfigured),
    );
    expect(checked, isFalse);
  });

  test('desktop offline reset persists until a ready new session', () async {
    final harness = DesktopWindowHarness();
    addTearDown(harness.dispose);
    final desktop = desktopFor(harness);
    await desktop.reset('test');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('xb_crisp_desktop_reset_test'), isTrue);
    await desktop.open(CrispConfig(websiteID: 'test'));
    final html = await harness.pageFile.readAsString();
    expect(html, contains('resetPending=true'));
    expect(html, contains('window.__xbCrispBootstrap=true'));
    expect(html, contains('window.__xbCrispLoadFailed=true'));
    expect(html, isNot(contains('app.crisp.chat')));
    expect(await desktop.sessionId(), 'new-session');
    expect(prefs.getBool('xb_crisp_desktop_reset_test'), isNull);
    harness.closed.complete();
    await harness.waitForPageRemoval();
    await expectLater(
      desktop.sessionId(),
      failure(CrispChatFailure.windowClosed),
    );
  });

  test(
    'decoded scalars preserve empty session and reset acknowledgement',
    () async {
      final harness = DesktopWindowHarness();
      addTearDown(harness.dispose);
      harness.bootstrapReply = 'loaded';
      final desktop = desktopFor(harness);
      await desktop.reset('test');
      await desktop.open(CrispConfig(websiteID: 'test'));
      final prefs = await SharedPreferences.getInstance();
      for (final empty in ['', 'null']) {
        harness.sessionReply = empty;
        expect(await desktop.sessionId(), isNull);
        expect(prefs.getBool('xb_crisp_desktop_reset_test'), isTrue);
      }
      harness.sessionReply = 'new-session';
      expect(await desktop.sessionId(), 'new-session');
      expect(prefs.getBool('xb_crisp_desktop_reset_test'), isNull);
      harness.writeReply = 'ok';
      await desktop.setString('Source', 'test');
      harness.writeReply = 'failed';
      await expectLater(
        desktop.setString('Source', 'test'),
        failure(CrispChatFailure.sessionDataFailed),
      );
      expect(harness.closeCalls, 1);
    },
  );

  test('same website reuses a ready window and awaits foreground', () async {
    final harness = DesktopWindowHarness();
    addTearDown(harness.dispose);
    var creates = 0;
    final desktop = DesktopCrispChatDriver(
      isWindowsOverride: false,
      available: () async => true,
      create: (_) async {
        creates++;
        return harness.window;
      },
    );
    await desktop.open(CrispConfig(websiteID: 'test'));
    expect(await desktop.sessionId(), 'new-session');
    final foreground = Completer<void>();
    harness.pendingForeground = foreground;
    var completed = false;
    final reused = desktop.open(CrispConfig(websiteID: 'test')).then((_) {
      completed = true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    expect(creates, 1);
    foreground.complete();
    await reused;
    expect(harness.foregroundCalls, 1);
    expect(harness.reloadCalls, 0);
    expect(harness.closeCalls, 0);
  });

  test('page that never produced a session reloads on the next open', () async {
    final harness = DesktopWindowHarness()..sessionReply = '';
    addTearDown(harness.dispose);
    final desktop = desktopFor(harness);
    await desktop.open(CrispConfig(websiteID: 'test'));
    expect(await desktop.sessionId(), isNull);
    await desktop.open(CrispConfig(websiteID: 'test'));
    expect(harness.reloadCalls, 1);
    expect(harness.foregroundCalls, 1);
    expect(harness.closeCalls, 0);
    harness.sessionReply = 'new-session';
    expect(await desktop.sessionId(), 'new-session');
  });

  test(
    'a previously ready page reloads after its session becomes empty',
    () async {
      final harness = DesktopWindowHarness();
      addTearDown(harness.dispose);
      final desktop = desktopFor(harness);
      await desktop.open(CrispConfig(websiteID: 'test'));
      expect(await desktop.sessionId(), 'new-session');
      harness.sessionReply = '';
      expect(await desktop.sessionId(), isNull);
      await desktop.open(CrispConfig(websiteID: 'test'));
      expect(harness.foregroundCalls, 1);
      expect(harness.reloadCalls, 1);
      harness.sessionReply = 'restored-session';
      expect(await desktop.sessionId(), 'restored-session');
    },
  );

  test(
    'script network failure remains sessionNotReady and can reload',
    () async {
      final harness = DesktopWindowHarness()
        ..sessionReply = '__xb_load_failed__';
      addTearDown(harness.dispose);
      final desktop = desktopFor(harness);
      await desktop.open(CrispConfig(websiteID: 'test'));
      await expectLater(
        desktop.sessionId(),
        failure(CrispChatFailure.sessionNotReady),
      );
      await desktop.open(CrispConfig(websiteID: 'test'));
      expect(harness.reloadCalls, 1);
      harness.sessionReply = 'new-session';
      expect(await desktop.sessionId(), 'new-session');
    },
  );

  test(
    'changing website waits for close before new create and HTML removal',
    () async {
      final first = DesktopWindowHarness(autoClose: false);
      final second = DesktopWindowHarness();
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      var creates = 0;
      final desktop = DesktopCrispChatDriver(
        isWindowsOverride: false,
        available: () async => true,
        create: (_) async => ++creates == 1 ? first.window : second.window,
      );
      await desktop.open(CrispConfig(websiteID: 'site-a'));
      final replaced = desktop.open(CrispConfig(websiteID: 'site-b'));
      await Future<void>.delayed(Duration.zero);
      expect(first.closeCalls, 1);
      expect(creates, 1);
      expect(await first.pageFile.exists(), isTrue);
      first.closed.complete();
      await replaced;
      expect(creates, 2);
      expect(await first.pageFile.exists(), isFalse);
      expect(await second.pageFile.exists(), isTrue);
      expect(await desktop.sessionId(), 'new-session');
    },
  );

  test(
    'unconfirmed close blocks reset and new windows while retaining HTML',
    () async {
      final first = DesktopWindowHarness(autoClose: false);
      final second = DesktopWindowHarness();
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      var creates = 0;
      final desktop = DesktopCrispChatDriver(
        isWindowsOverride: false,
        available: () async => true,
        create: (_) async => ++creates == 1 ? first.window : second.window,
        closeTimeout: const Duration(milliseconds: 20),
      );
      await desktop.open(CrispConfig(websiteID: 'test'));
      await expectLater(
        desktop.reset('test'),
        failure(CrispChatFailure.closeFailed),
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('xb_crisp_desktop_reset_test'), isTrue);
      expect(await first.pageFile.exists(), isTrue);
      await expectLater(
        desktop.sessionId(),
        failure(CrispChatFailure.windowClosed),
      );
      await expectLater(
        desktop.open(CrispConfig(websiteID: 'test')),
        failure(CrispChatFailure.closeFailed),
      );
      expect(creates, 1);
      first.closed.complete();
      await first.waitForPageRemoval();
      final restarted = desktopFor(second);
      await restarted.open(CrispConfig(websiteID: 'test'));
      expect(
        await second.pageFile.readAsString(),
        contains('resetPending=true'),
      );
      second.closed.complete();
      await second.waitForPageRemoval();
      await desktop.reset('test');
      expect(creates, 1);
    },
  );

  test(
    'late create after timeout closes its own window and leaves new view active',
    () async {
      final late = DesktopWindowHarness(autoClose: false);
      final current = DesktopWindowHarness()..sessionReply = 'current-session';
      addTearDown(late.dispose);
      addTearDown(current.dispose);
      final pending = Completer<Webview>();
      var creates = 0;
      final desktop = DesktopCrispChatDriver(
        isWindowsOverride: false,
        available: () async => true,
        create: (_) =>
            ++creates == 1 ? pending.future : Future.value(current.window),
        startupTimeout: const Duration(milliseconds: 20),
        closeTimeout: const Duration(milliseconds: 20),
      );
      await expectLater(
        desktop.open(CrispConfig(websiteID: 'old')),
        failure(CrispChatFailure.startupTimeout),
      );
      await desktop.open(CrispConfig(websiteID: 'new'));
      pending.complete(late.window);
      await Future<void>.delayed(Duration.zero);
      expect(late.closeCalls, 1);
      expect(late.page, isNull);
      late.closed.complete();
      await Future<void>.delayed(Duration.zero);
      expect(await desktop.sessionId(), 'current-session');
      expect(await current.pageFile.exists(), isTrue);
      expect(current.closeCalls, 0);
    },
  );

  test(
    'create failure is startupFailed and a new attempt is possible',
    () async {
      final harness = DesktopWindowHarness();
      addTearDown(harness.dispose);
      var attempts = 0;
      final desktop = DesktopCrispChatDriver(
        isWindowsOverride: false,
        available: () async => true,
        create: (_) async {
          if (++attempts == 1) throw StateError('private-path');
          return harness.window;
        },
      );
      await expectLater(
        desktop.open(CrispConfig(websiteID: 'test')),
        failure(CrispChatFailure.startupFailed),
      );
      await desktop.open(CrispConfig(websiteID: 'test'));
      expect(await desktop.sessionId(), 'new-session');
    },
  );

  test(
    'missing inline bootstrap times out and closes the created view',
    () async {
      final harness = DesktopWindowHarness()..bootstrapReply = '';
      addTearDown(harness.dispose);
      final desktop = desktopFor(
        harness,
        startupTimeout: const Duration(milliseconds: 20),
      );
      await expectLater(
        desktop.open(CrispConfig(websiteID: 'test')),
        failure(CrispChatFailure.startupTimeout),
      );
      expect(harness.closeCalls, 1);
      await harness.waitForPageRemoval();
    },
  );

  test(
    'JS write timeout retires old view and ignores a late acknowledgement',
    () async {
      final old = DesktopWindowHarness(autoClose: false);
      final current = DesktopWindowHarness()..sessionReply = 'current-session';
      addTearDown(old.dispose);
      addTearDown(current.dispose);
      var creates = 0;
      final desktop = DesktopCrispChatDriver(
        isWindowsOverride: false,
        available: () async => true,
        create: (_) async => ++creates == 1 ? old.window : current.window,
        ioTimeout: const Duration(milliseconds: 50),
        closeTimeout: const Duration(milliseconds: 20),
      );
      await desktop.open(CrispConfig(websiteID: 'test'));
      old.pendingWrite = Completer<String?>();
      await expectLater(
        desktop.setString('Email', 'test@example.invalid'),
        failure(CrispChatFailure.sessionDataFailed),
      );
      expect(old.closeCalls, 1);
      expect(await old.pageFile.exists(), isTrue);
      await expectLater(
        desktop.open(CrispConfig(websiteID: 'test')),
        failure(CrispChatFailure.closeFailed),
      );
      old.closed.complete();
      await old.waitForPageRemoval();
      await desktop.open(CrispConfig(websiteID: 'test'));
      old.pendingWrite!.complete('ok');
      await Future<void>.delayed(Duration.zero);
      expect(await desktop.sessionId(), 'current-session');
      expect(current.closeCalls, 0);
    },
  );

  test(
    'late session read after reset cannot clear the new pending marker',
    () async {
      final harness = DesktopWindowHarness();
      addTearDown(harness.dispose);
      final desktop = desktopFor(harness);
      await desktop.reset('test');
      await desktop.open(CrispConfig(websiteID: 'test'));
      harness.pendingSession = Completer<String?>();
      final staleRead = desktop.sessionId();
      final assertion = expectLater(
        staleRead,
        failure(CrispChatFailure.cancelled),
      );
      await desktop.reset('test');
      harness.pendingSession!.complete('old-session');
      await assertion;
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('xb_crisp_desktop_reset_test'), isTrue);
    },
  );

  test(
    'late reset acknowledgement removal commits before the new true marker',
    () async {
      final store = DelayedPreferencesStore();
      final harness = DesktopWindowHarness();
      addTearDown(harness.dispose);
      final desktop = desktopFor(
        harness,
        ioTimeout: const Duration(milliseconds: 50),
        preferences: () async => store.preferences,
      );
      await desktop.reset('test');
      await desktop.open(CrispConfig(websiteID: 'test'));
      store.pendingRemove = Completer<void>();
      final read = desktop.sessionId();
      final reading = expectLater(read, failure(CrispChatFailure.resetFailed));
      await store.removeStarted.future;
      await reading;
      final reset = desktop.reset('test');
      await Future<void>.delayed(Duration.zero);
      expect(store.calls, ['set:true', 'remove']);
      store.pendingRemove!.complete();
      await reset;
      expect(store.calls, ['set:true', 'remove', 'set:true']);
      final persisted = await store.getAll();
      expect(persisted['flutter.xb_crisp_desktop_reset_test'], isTrue);
      expect(store.preferences.getBool('xb_crisp_desktop_reset_test'), isTrue);
    },
  );

  test('failed reset marker persistence still closes the old window', () async {
    final store = DelayedPreferencesStore();
    final harness = DesktopWindowHarness();
    addTearDown(harness.dispose);
    final desktop = desktopFor(
      harness,
      preferences: () async => store.preferences,
    );
    await desktop.open(CrispConfig(websiteID: 'test'));
    store.failSet = true;
    await expectLater(
      desktop.reset('test'),
      failure(CrispChatFailure.resetFailed),
    );
    expect(harness.closeCalls, 1);
    await harness.waitForPageRemoval();
    expect(
      (await store.getAll())['flutter.xb_crisp_desktop_reset_test'],
      isNull,
    );
  });

  test(
    'session read timeout is bounded and does not acknowledge a late session',
    () async {
      final harness = DesktopWindowHarness();
      addTearDown(harness.dispose);
      final desktop = desktopFor(
        harness,
        ioTimeout: const Duration(milliseconds: 50),
      );
      await desktop.reset('test');
      await desktop.open(CrispConfig(websiteID: 'test'));
      harness.pendingSession = Completer<String?>();
      await expectLater(
        desktop.sessionId(),
        failure(CrispChatFailure.sessionNotReady),
      );
      harness.pendingSession!.complete('late-session');
      await Future<void>.delayed(Duration.zero);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('xb_crisp_desktop_reset_test'), isTrue);
    },
  );

  test(
    'Windows profile remains absolute, persistent and scoped to website',
    () async {
      final root = await Directory.systemTemp.createTemp('crisp-profile-test-');
      addTearDown(() => root.delete(recursive: true));
      final harnesses = <DesktopWindowHarness>[];
      final profiles = <String>[];
      addTearDown(() async {
        for (final harness in harnesses) {
          await harness.dispose();
        }
      });
      final desktop = DesktopCrispChatDriver(
        isWindowsOverride: true,
        available: () async => true,
        cacheDirectory: () async => root,
        create: (configuration) async {
          profiles.add(configuration.windows.userDataFolder);
          final harness = DesktopWindowHarness();
          harnesses.add(harness);
          return harness.window;
        },
      );
      await desktop.open(CrispConfig(websiteID: 'website-a'));
      final profile = Directory(profiles.single);
      expect(profile.absolute.path, profile.path);
      expect(await profile.exists(), isTrue);
      final cookie = File('${profile.path}/persistent-cookie');
      await cookie.writeAsString('test-session');
      await desktop.reset('website-a');
      await desktop.open(CrispConfig(websiteID: 'website-a'));
      expect(profiles[1], profiles[0]);
      expect(await cookie.readAsString(), 'test-session');
      await desktop.reset('website-a');
      await desktop.open(CrispConfig(websiteID: '../different-site'));
      expect(profiles[2], isNot(profiles[0]));
      expect(profiles[2], startsWith(root.path));
      await desktop.reset('../different-site');
    },
  );

  test(
    'Windows unwritable profile fails before native window creation',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'crisp-invalid-profile-test-',
      );
      addTearDown(() => root.delete(recursive: true));
      final blocked = File('${root.path}/blocked');
      await blocked.writeAsString('occupied');
      var created = false;
      final desktop = DesktopCrispChatDriver(
        isWindowsOverride: true,
        available: () async => true,
        cacheDirectory: () async => Directory(blocked.path),
        create: (_) async {
          created = true;
          return MockWindow();
        },
      );
      await expectLater(
        desktop.open(CrispConfig(websiteID: 'test')),
        failure(CrispChatFailure.profileUnavailable),
      );
      expect(created, isFalse);
    },
  );

  test(
    'Windows relative profile and profile resolution timeout are typed',
    () async {
      for (final directory in [
        () async => Directory('relative-profile'),
        () => Completer<Directory>().future,
      ]) {
        final desktop = DesktopCrispChatDriver(
          isWindowsOverride: true,
          available: () async => true,
          cacheDirectory: directory,
          ioTimeout: const Duration(milliseconds: 20),
        );
        await expectLater(
          desktop.open(CrispConfig(websiteID: 'test')),
          failure(CrispChatFailure.profileUnavailable),
        );
      }
    },
  );

  test('macOS/Linux do not resolve the Windows profile directory', () async {
    var resolved = false;
    final harness = DesktopWindowHarness();
    addTearDown(harness.dispose);
    final desktop = DesktopCrispChatDriver(
      isWindowsOverride: false,
      available: () async => true,
      create: (_) async => harness.window,
      cacheDirectory: () async {
        resolved = true;
        throw StateError('not used');
      },
    );
    await desktop.open(CrispConfig(websiteID: 'test'));
    expect(resolved, isFalse);
    await desktop.reset('test');
  });

  test('desktop inline config escapes HTML script delimiters', () {
    final html = desktopCrispHtml('</script><script>alert(1)', null, false);
    expect(html, isNot(contains('</script><script>alert(1)')));
    expect(html, contains(r'\u003c/script>'));
  });
  test('0.4.0 launch errors retire only the failed window', () async {
    final h = DesktopWindowHarness();
    addTearDown(h.dispose);
    when(
      () => h.window.launch(any()),
    ).thenAnswer((_) async => throw StateError('navigation failed'));
    await expectLater(
      desktopFor(h).open(CrispConfig(websiteID: 'test')),
      failure(CrispChatFailure.startupFailed),
    );
    expect(h.closeCalls, 1);
  });

  test(
    'navigation stays synchronous and old-window links cannot launch browser',
    () async {
      final h = DesktopWindowHarness();
      addTearDown(h.dispose);
      final launched = <Uri>[];
      final d = DesktopCrispChatDriver(
        isWindowsOverride: false,
        available: () async => true,
        create: (_) async => h.window,
        openExternal: (uri) async {
          launched.add(uri);
          return true;
        },
      );
      await d.open(CrispConfig(websiteID: 'test'));
      expect(h.navigate!(h.page!), isTrue);
      expect(h.navigate!('https://example.invalid/help'), isFalse);
      expect(launched, isEmpty);
      await Future<void>.delayed(Duration.zero);
      expect(launched.single.host, 'example.invalid');
      await d.reset('test');
      expect(h.navigate!('https://example.invalid/old-account'), isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(launched, hasLength(1));
    },
  );

  test(
    'top-level load error invalidates ready session and retry reloads',
    () async {
      final h = DesktopWindowHarness();
      addTearDown(h.dispose);
      final d = desktopFor(h);
      await d.open(CrispConfig(websiteID: 'test'));
      expect(await d.sessionId(), 'new-session');
      h.loadErrors.add(
        const WebviewLoadError(
          url: 'file:///test',
          kind: WebviewLoadErrorKind.connection,
          description: 'test',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await expectLater(
        d.sessionId(),
        failure(CrispChatFailure.sessionNotReady),
      );
      await d.open(CrispConfig(websiteID: 'test'));
      expect(h.reloadCalls, 1);
      expect(await d.sessionId(), 'new-session');
    },
  );

  test('decoded session strings are not decoded a second time', () async {
    final h = DesktopWindowHarness();
    addTearDown(h.dispose);
    final d = desktopFor(h);
    await d.open(CrispConfig(websiteID: 'test'));
    for (final id in ['123', 'true', '"quoted"']) {
      h.sessionReply = id;
      expect(await d.sessionId(), id);
    }
  });
  test(
    'desktop chat is revealed only after current account context succeeds',
    () async {
      final h = DesktopWindowHarness();
      addTearDown(h.dispose);
      await CrispSupportService.setDriverForTest(desktopFor(h));
      h.pendingWrite = Completer<String?>();
      final opening = CrispSupportService.openWithResult();
      while (h.page == null) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(h.revealCalls, 0);
      h.pendingWrite!.complete('ok');
      expect((await opening).opened, isTrue);
      expect(h.revealCalls, 1);
    },
  );

  test('failed context never reveals the desktop chat', () async {
    final h = DesktopWindowHarness()..writeReply = 'failed';
    addTearDown(h.dispose);
    await CrispSupportService.setDriverForTest(desktopFor(h));
    expect(
      (await CrispSupportService.openWithResult()).failure,
      CrispChatFailure.sessionDataFailed,
    );
    expect(h.revealCalls, 0);
  });

  test(
    'failed online script closes child before recovery without clearing profile',
    () async {
      final h = DesktopWindowHarness()..sessionReply = '__xb_load_failed__';
      addTearDown(h.dispose);
      await CrispSupportService.setDriverForTest(desktopFor(h));
      final result = await CrispSupportService.openWithResult();
      expect(result.failure, CrispChatFailure.sessionNotReady);
      expect(h.closeCalls, 1);
      await h.waitForPageRemoval();
    },
  );
}
