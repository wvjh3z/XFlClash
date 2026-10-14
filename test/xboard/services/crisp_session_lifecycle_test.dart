import 'dart:async';
import 'dart:io';

import 'package:crisp_chat/crisp_chat.dart';
import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/services/crisp_chat_driver.dart';
import 'package:fl_clash/xboard/services/crisp_support_service.dart';

class FakeDriver implements CrispChatDriver {
  final calls = <String>[];
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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

  test(
    'desktop unavailable returns failure without browser navigation',
    () async {
      final desktop = DesktopCrispChatDriver(available: () async => false);
      await expectLater(
        desktop.open(CrispConfig(websiteID: 'test')),
        throwsStateError,
      );
    },
  );

  test(
    'desktop closed/offline reset persists until a ready new session',
    () async {
      final window = MockWindow();
      final closed = Completer<void>();
      String? page;
      when(() => window.onClose).thenAnswer((_) => closed.future);
      when(() => window.launch(any())).thenAnswer((i) {
        page = i.positionalArguments.first as String;
      });
      when(() => window.close()).thenAnswer((_) {});
      when(
        () => window.evaluateJavaScript(any()),
      ).thenAnswer((_) async => 'new-session');
      final desktop = DesktopCrispChatDriver(
        available: () async => true,
        create: () async => window,
      );
      await desktop.reset('test');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('xb_crisp_desktop_reset_test'), isTrue);
      await desktop.open(CrispConfig(websiteID: 'test'));
      final html = await File.fromUri(Uri.parse(page!)).readAsString();
      expect(html, contains('resetPending=true'));
      expect(html, isNot(contains('app.crisp.chat')));
      expect(await desktop.sessionId(), 'new-session');
      expect(prefs.getBool('xb_crisp_desktop_reset_test'), isNull);
      closed.complete();
      await Future<void>.delayed(Duration.zero);
      expect(await desktop.sessionId(), isNull);
    },
  );

  test(
    'Windows/Linux JSON scalars preserve readiness, reset flag and write acknowledgement',
    () async {
      final window = MockWindow();
      final closed = Completer<void>();
      var wire = '""';
      when(() => window.onClose).thenAnswer((_) => closed.future);
      when(() => window.launch(any())).thenAnswer((_) {});
      when(() => window.close()).thenAnswer((_) {});
      when(
        () => window.evaluateJavaScript(any()),
      ).thenAnswer((_) async => wire);
      final desktop = DesktopCrispChatDriver(
        available: () async => true,
        create: () async => window,
      );
      await desktop.reset('test');
      await desktop.open(CrispConfig(websiteID: 'test'));
      final prefs = await SharedPreferences.getInstance();
      for (final empty in ['""', '', 'null']) {
        wire = empty;
        expect(await desktop.sessionId(), isNull);
        expect(prefs.getBool('xb_crisp_desktop_reset_test'), isTrue);
      }
      wire = '"new-session"';
      expect(await desktop.sessionId(), 'new-session');
      expect(prefs.getBool('xb_crisp_desktop_reset_test'), isNull);
      wire = '"ok"';
      await desktop.setString('Source', 'test');
      wire = '"failed"';
      await expectLater(desktop.setString('Source', 'test'), throwsStateError);
      closed.complete();
      await Future<void>.delayed(Duration.zero);
    },
  );

  test('desktop inline config escapes HTML script delimiters', () {
    final html = desktopCrispHtml('</script><script>alert(1)', null, false);
    expect(html, isNot(contains('</script><script>alert(1)')));
    expect(html, contains(r'\u003c/script>'));
  });
}
