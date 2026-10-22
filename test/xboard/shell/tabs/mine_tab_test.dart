/// W4.3·W4.4·W4.5 — MineTab 单测（游客卡 / 账号卡用量 / 重置入口阈值 / 设置入口）。
library;

import 'dart:async';
import 'package:crisp_chat/crisp_chat.dart';
import 'package:fl_clash/xboard/services/crisp_chat_driver.dart';
import 'package:fl_clash/xboard/services/crisp_support_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart'
    show MethodCall, MethodChannel, PlatformException, SystemChannels;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:fl_clash/xboard/config/xboard_config.dart';
import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/models/xb_domain_subscription.dart';
import 'package:fl_clash/xboard/models/xb_result.dart';
import 'package:fl_clash/xboard/providers/auth_state_provider.dart';
import 'package:fl_clash/xboard/providers/user_profile_provider.dart';
import 'package:fl_clash/xboard/providers/xboard_providers.dart';
import 'package:fl_clash/xboard/sdk/xboard_service.dart';
import 'package:fl_clash/xboard/shell/tabs/mine/mine_tab.dart';
import 'package:fl_clash/xboard/widgets/xb_components.dart' show XbSkeletonBar;

class _MockService extends Mock implements XboardService {}

class _MockCrispDriver extends Mock implements CrispChatDriver {}

class _FakeAuth extends AuthStateNotifier {
  _FakeAuth(this._initial);
  final AuthState _initial;
  @override
  AuthState build() => _initial;
}

XbDomainSubscription _sub({required int total, required int used}) =>
    XbDomainSubscription(
      email: 'demo@example.com',
      uuid: 'uid-123',
      planName: '专业版',
      totalBytes: total,
      usedBytes: used,
      expiredAt: DateTime(2026, 12, 31),
      planId: 1,
    );

Future<void> pumpMine(
  WidgetTester tester, {
  required AuthState auth,
  XbDomainSubscription? sub,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authStateProvider.overrideWith(() => _FakeAuth(auth)),
        if (sub != null) userProfileProvider.overrideWith((ref) async => sub),
      ],
      child: const MaterialApp(home: Scaffold(body: MineTab())),
    ),
  );
  // 注：账号卡加载骨架（XbSkeletonBar）含无限 shimmer 动画，pumpAndSettle 会永不收敛。
  // 用固定多次 pump 让 async provider 落地 + skeleton 被真实卡片替换。
  await tester.pump(); // 触发 provider future
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
  // 账号卡进入时有「流量数字 count-up + 进度条填充」入场动画（_fill 700ms 有限动画）。
  // 再 pump 让它跑完，断言取终值（用量%/流量数字）。
  await tester.pump(const Duration(milliseconds: 800));
}

void main() {
  const gb = 1024 * 1024 * 1024;
  const urlChannel = MethodChannel('plugins.flutter.io/url_launcher');

  setUpAll(() => registerFallbackValue(CrispConfig(websiteID: 'test')));

  testWidgets('客服打开期间显示进度并防止重复点击', (tester) async {
    XboardConfig.bind(
      const XboardConfig(
        subscribeUserAgent: 'test',
        devApiEndpoint: 'https://test.invalid',
        devSubscriptionEndpoint: 'https://test.invalid',
        debug: false,
        kIsTest: true,
        crispWebsiteId: 'test',
      ),
    );
    addTearDown(XboardConfig.resetForTest);
    final driver = _MockCrispDriver();
    final opened = Completer<void>();
    when(() => driver.sessionLoaded).thenAnswer((_) => const Stream.empty());
    when(() => driver.open(any())).thenAnswer((_) => opened.future);
    when(
      () => driver.sessionId(),
    ).thenAnswer((_) => Future<String?>.value('ready'));
    when(() => driver.setString(any(), any())).thenAnswer((_) async {});
    await tester.runAsync(() => CrispSupportService.setDriverForTest(driver));
    await pumpMine(tester, auth: AuthState.unauthenticated);
    await tester.ensureVisible(find.text('在线客服'));
    await tester.runAsync(() => tester.tap(find.text('在线客服')));
    await tester.pump();
    expect(find.text('正在打开客服…'), findsOneWidget);
    await tester.tap(find.text('正在打开客服…'));
    await tester.runAsync(() async {
      opened.complete();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(find.text('在线客服'), findsOneWidget);
    verify(() => driver.open(any())).called(1);
  });

  group('客服失败提示与运行组件下载', () {
    setUp(() {
      XboardConfig.bind(
        const XboardConfig(
          subscribeUserAgent: 'test',
          devApiEndpoint: 'https://test.invalid',
          devSubscriptionEndpoint: 'https://test.invalid',
          debug: false,
          kIsTest: true,
          crispWebsiteId: 'test',
        ),
      );
    });
    tearDown(XboardConfig.resetForTest);

    Future<void> pumpFailure(
      WidgetTester tester,
      CrispChatFailure failure,
    ) async {
      final driver = _MockCrispDriver();
      when(() => driver.sessionLoaded).thenAnswer((_) => const Stream.empty());
      when(() => driver.open(any())).thenThrow(CrispChatException(failure));
      await tester.runAsync(() => CrispSupportService.setDriverForTest(driver));
      await pumpMine(tester, auth: AuthState.unauthenticated);
      await tester.ensureVisible(find.text('在线客服'));
      await tester.runAsync(() async {
        await tester.tap(find.text('在线客服'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pump();
      // 运行组件确认框等待用户决策时，提交 spinner 仍会转，不能 pumpAndSettle。
      await tester.pump(const Duration(milliseconds: 300));
    }

    List<MethodCall> mockBrowser(
      WidgetTester tester, {
      bool succeeds = true,
      bool throws = false,
      Future<bool>? pending,
    }) {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        urlChannel,
        (call) async {
          calls.add(call);
          if (throws) throw PlatformException(code: 'launch_failed');
          return pending ?? succeeds;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          urlChannel,
          null,
        ),
      );
      return calls;
    }

    Future<void> pumpSupportIdle(WidgetTester tester) async {
      // Stream cancellation/method-channel completions can cross the real async
      // zone used by the preceding single-flight test. Give them one bounded
      // turn, then assert actual submit completion instead of settling every
      // animation in MineTab (a busy spinner would otherwise wait ten minutes).
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      for (var frame = 0; frame < 20; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (find.text('在线客服').evaluate().isNotEmpty &&
            find.byType(AlertDialog).evaluate().isEmpty) {
          break;
        }
      }
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('正在打开客服…'), findsNothing);
      expect(find.text('在线客服'), findsOneWidget);
    }

    Future<void> finishToast(WidgetTester tester) async {
      await pumpSupportIdle(tester);
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('缺少 WebView2 → 说明组件名称；取消不会打开浏览器', (tester) async {
      final calls = mockBrowser(tester);
      await pumpFailure(tester, CrispChatFailure.webView2Unavailable);
      expect(find.text('需要安装客服运行组件'), findsOneWidget);
      expect(
        find.textContaining('Microsoft Edge WebView2 Runtime'),
        findsOneWidget,
      );
      expect(calls, isEmpty);
      await tester.tap(find.text('取消'));
      await pumpSupportIdle(tester);
      expect(find.text('需要安装客服运行组件'), findsNothing);
      expect(find.text('在线客服'), findsOneWidget);
      expect(calls, isEmpty);
    });

    testWidgets('用户点击下载 → 仅用系统浏览器打开微软官方页面', (tester) async {
      final calls = mockBrowser(tester);
      await pumpFailure(tester, CrispChatFailure.webView2Unavailable);
      await tester.tap(find.text('前往下载'));
      await pumpSupportIdle(tester);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'launch');
      final arguments = calls.single.arguments as Map;
      expect(
        arguments['url'],
        'https://developer.microsoft.com/microsoft-edge/webview2/',
      );
      expect(arguments['useWebView'], isFalse);
      expect(arguments['useSafariVC'], isFalse);
      expect(find.text('在线客服'), findsOneWidget);
    });

    for (final throws in [false, true]) {
      testWidgets('浏览器打开${throws ? '抛异常' : '返回失败'} → 显示可操作提示并恢复入口', (
        tester,
      ) async {
        final calls = mockBrowser(tester, succeeds: false, throws: throws);
        await pumpFailure(tester, CrispChatFailure.webView2Unavailable);
        await tester.tap(find.text('前往下载'));
        await pumpSupportIdle(tester);
        expect(calls, hasLength(1));
        expect(find.text('下载页面无法打开，请使用浏览器访问微软 WebView2 官网'), findsOneWidget);
        expect(find.text('在线客服'), findsOneWidget);
        await finishToast(tester);
      });
    }

    testWidgets('浏览器迟到失败时页面已销毁 → 静默结束', (tester) async {
      final launched = Completer<bool>();
      mockBrowser(tester, pending: launched.future);
      await pumpFailure(tester, CrispChatFailure.webView2Unavailable);
      await tester.tap(find.text('前往下载'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      launched.complete(false);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('下载页面无法打开，请使用浏览器访问微软 WebView2 官网'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('数据目录失败 → 提示存储权限，与网络加载失败区别', (tester) async {
      await pumpFailure(tester, CrispChatFailure.profileUnavailable);
      expect(find.text('客服数据无法保存，请检查应用的存储权限或可用空间后重试'), findsOneWidget);
      expect(find.text('客服加载失败，请检查网络后重试'), findsNothing);
      expect(find.text('需要安装客服运行组件'), findsNothing);
      await finishToast(tester);
    });

    testWidgets('会话网络未就绪 → 提示检查网络，不引导安装组件', (tester) async {
      await pumpFailure(tester, CrispChatFailure.sessionNotReady);
      expect(find.text('客服加载失败，请检查网络后重试'), findsOneWidget);
      expect(find.text('客服数据无法保存，请检查应用的存储权限或可用空间后重试'), findsNothing);
      expect(find.text('需要安装客服运行组件'), findsNothing);
      await finishToast(tester);
    });

    testWidgets('macOS/Linux 组件不可用 → 不提供 Windows Runtime 下载', (tester) async {
      final calls = mockBrowser(tester);
      await pumpFailure(tester, CrispChatFailure.webViewUnavailable);
      expect(find.text('当前系统的客服组件不可用，请检查应用安装是否完整'), findsOneWidget);
      expect(find.text('需要安装客服运行组件'), findsNothing);
      expect(calls, isEmpty);
      await finishToast(tester);
    });

    for (final failure in [
      CrispChatFailure.windowClosed,
      CrispChatFailure.cancelled,
      CrispChatFailure.notConfigured,
    ]) {
      testWidgets('${failure.name} → 静默结束，保留可点击入口', (tester) async {
        final calls = mockBrowser(tester);
        await pumpFailure(tester, failure);
        await pumpSupportIdle(tester);
        expect(find.textContaining('客服'), findsOneWidget);
        expect(find.text('在线客服'), findsOneWidget);
        expect(find.byType(AlertDialog), findsNothing);
        expect(calls, isEmpty);
      });
    }
  });

  testWidgets('游客态 → 登录引导卡（R6.10）', (tester) async {
    await pumpMine(tester, auth: AuthState.unauthenticated);
    expect(find.text('未登录'), findsOneWidget);
    expect(find.text('登录后同步专属节点与套餐'), findsOneWidget);
    expect(find.text('登录 / 注册'), findsOneWidget);
    // 游客态设置区只有「设置」，无订单/退出。
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('退出登录'), findsNothing);
  });

  testWidgets('已登录 → 账号卡显示邮箱(掩码)/套餐/用量%', (tester) async {
    await pumpMine(
      tester,
      auth: AuthState.authenticated,
      sub: _sub(total: 100 * gb, used: 37 * gb),
    );
    expect(find.text('demo@example.com'), findsOneWidget);
    expect(find.text('专业版', findRichText: true), findsOneWidget);
    // 紧凑卡：用量% 在流量行右侧「已用 N%」（去掉了原「本月已用流量（已使用 N%）」标签行）。
    expect(find.text('已用 37%'), findsOneWidget);
    expect(find.text('退出登录'), findsOneWidget);
    // 邮箱后有复制按钮（已登录账号卡）。
    expect(find.byIcon(Icons.content_copy), findsOneWidget);
  });

  testWidgets('点复制按钮 → 邮箱写入剪贴板 + toast', (tester) async {
    // 拦截剪贴板平台调用并记录写入值。
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await pumpMine(
      tester,
      auth: AuthState.authenticated,
      sub: _sub(total: 100 * gb, used: 37 * gb),
    );
    await tester.tap(find.byIcon(Icons.content_copy));
    await tester.pump();
    expect(copied, 'demo@example.com', reason: '点复制应把邮箱写入剪贴板');
    expect(find.text('已复制邮箱'), findsOneWidget, reason: 'toast 提示');
    // 消耗 xbToast 的 2s 自动消失 timer,避免 pending timer 报错。
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('游客态 → 无复制按钮（无邮箱）', (tester) async {
    await pumpMine(tester, auth: AuthState.unauthenticated);
    expect(find.byIcon(Icons.content_copy), findsNothing);
  });

  testWidgets('用量 <90% → 不显示流量重置入口（R6.3）', (tester) async {
    await pumpMine(
      tester,
      auth: AuthState.authenticated,
      sub: _sub(total: 100 * gb, used: 50 * gb),
    );
    expect(find.text('流量重置'), findsNothing);
  });

  testWidgets('用量 ≥90% → 显示流量重置入口（R6.3）', (tester) async {
    await pumpMine(
      tester,
      auth: AuthState.authenticated,
      sub: _sub(total: 100 * gb, used: 95 * gb),
    );
    expect(find.text('流量重置'), findsOneWidget);
  });

  testWidgets('已订阅 → 续费 + 购买/更改套餐双入口（R6.4-R6.6）', (tester) async {
    await pumpMine(
      tester,
      auth: AuthState.authenticated,
      sub: _sub(total: 100 * gb, used: 10 * gb),
    );
    expect(find.text('续费当前套餐'), findsOneWidget);
    expect(find.text('购买 / 更改套餐'), findsOneWidget);
  });

  testWidgets(
    '账号加载失败 → 点重新加载 → 黄横幅出现，重试落定后横幅消失（不卡死）',
    (tester) async {
      final svc = _MockService();
      // 重试调反腐层 getSubscription：延迟后返失败（XbResult 永不抛、必落定）→ 横幅应能正常撤除。
      when(svc.getSubscription).thenAnswer((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        return XbResult.failure(const XbNetwork(XbNetworkKind.unknown, 'down'));
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authStateProvider.overrideWith(
              () => _FakeAuth(AuthState.authenticated),
            ),
            xboardServiceProvider.overrideWithValue(svc),
            userProfileProvider.overrideWith(
              (ref) async => throw Exception('down'),
            ),
          ],
          child: const MaterialApp(home: Scaffold(body: MineTab())),
        ),
      );
      // keepAlive 首次错误经 AsyncLoading(error:)→AsyncError，pumpAndSettle 落定到失败卡。
      try {
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
      } catch (_) {}
      expect(find.text('账号信息加载失败'), findsOneWidget);

      // 点重新加载 → 同步 setState(_retrying=true) → 黄横幅出现。
      await tester.tap(find.text('重新加载'));
      await tester.pump();
      expect(find.text('正在刷新服务，请稍候…'), findsOneWidget);
      // 11d：重试态与首次加载同布局——卡片不丢（骨架卡占位 + 禁用按钮行），不只是一条横幅。
      expect(
        find.byType(XbSkeletonBar),
        findsWidgets,
        reason: '重试态保留骨架卡占位（卡片不丢，原型 11d）',
      );
      expect(find.text('续费当前套餐'), findsOneWidget, reason: '重试态显示禁用的续费/购买按钮行');

      // 等 getSubscription 落定 + invalidate + setState(_retrying=false)。
      // _retry await 的是反腐层（必返回），故横幅一定撤除（验证不卡死）。
      try {
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
      } catch (_) {}
      expect(
        find.text('正在刷新服务，请稍候…'),
        findsNothing,
        reason: '重试落定后横幅必须消失（不卡死）',
      );
      expect(find.text('账号信息加载失败'), findsOneWidget, reason: '重试仍失败 → 回到失败卡');
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  group('在线客服入口（D9 Crisp，按 crispWebsiteId 显隐）', () {
    tearDown(XboardConfig.resetForTest);

    testWidgets('crispWebsiteId 空（默认）→ 入口隐藏', (tester) async {
      // 占位默认 crispWebsiteId='' → CrispSupportService.isEnabled false。
      await pumpMine(
        tester,
        auth: AuthState.authenticated,
        sub: _sub(total: 100 * gb, used: 10 * gb),
      );
      expect(find.text('在线客服'), findsNothing);
    });

    testWidgets('crispWebsiteId 有值 → 入口显示（已登录）', (tester) async {
      XboardConfig.bind(
        const XboardConfig(
          subscribeUserAgent: 'x flclash',
          devApiEndpoint: 'https://x',
          devSubscriptionEndpoint: 'https://x',
          debug: false,
          kIsTest: true,
          crispWebsiteId: 'ws-abc-123',
        ),
      );
      await pumpMine(
        tester,
        auth: AuthState.authenticated,
        sub: _sub(total: 100 * gb, used: 10 * gb),
      );
      expect(find.text('在线客服'), findsOneWidget);
    });

    testWidgets('crispWebsiteId 有值 → 游客也显示入口', (tester) async {
      XboardConfig.bind(
        const XboardConfig(
          subscribeUserAgent: 'x flclash',
          devApiEndpoint: 'https://x',
          devSubscriptionEndpoint: 'https://x',
          debug: false,
          kIsTest: true,
          crispWebsiteId: 'ws-abc-123',
        ),
      );
      await pumpMine(tester, auth: AuthState.unauthenticated);
      expect(find.text('在线客服'), findsOneWidget);
    });
  });
}
