/// W2.9.5 — XboardStateView 4 状态 + 7 XbDomainError 子类型 widget test。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart'
    show BusinessErrorKind, NetworkErrorKind, RateLimitKind;

import 'package:fl_clash/xboard/models/xb_domain_error.dart';
import 'package:fl_clash/xboard/widgets/xboard_state_view.dart';

void main() {
  Future<void> pump(WidgetTester tester, XbViewState<String> state,
      {bool offline = false, VoidCallback? onRetry}) {
    return tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: XboardStateView<String>(
          state: state,
          isOffline: offline,
          onRetry: onRetry,
          onData: (d) => Text('DATA:$d'),
          isEmpty: (d) => d.isEmpty,
        ),
      ),
    ));
  }

  group('4 状态', () {
    testWidgets('loading → CircularProgressIndicator', (t) async {
      await pump(t, const XbViewLoading());
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('data → onData 渲染', (t) async {
      await pump(t, const XbViewData('hello'));
      expect(find.text('DATA:hello'), findsOneWidget);
    });

    testWidgets('empty（isEmpty=true）→ 暂无数据', (t) async {
      await pump(t, const XbViewData(''));
      expect(find.text('暂无数据'), findsOneWidget);
    });

    testWidgets('offline → 离线提示', (t) async {
      await pump(t, const XbViewLoading(), offline: true);
      expect(find.textContaining('离线'), findsOneWidget);
    });
  });

  group('error 态 7 子类型分流', () {
    testWidgets('XbUnauthorized → 登录已过期', (t) async {
      await pump(t, const XbViewError(XbUnauthorized('x')));
      expect(find.textContaining('登录已过期'), findsOneWidget);
    });

    testWidgets('XbRateLimit(5min) → 倒计时文案', (t) async {
      await pump(t, const XbViewError(XbRateLimit(RateLimitKind.login, 5, 'x')));
      expect(find.textContaining('5 分钟'), findsOneWidget);
    });

    testWidgets('XbBusiness(banned) → 本地化文案', (t) async {
      await pump(t,
          const XbViewError(XbBusiness(BusinessErrorKind.banned, 'raw', null)));
      expect(find.textContaining('封禁'), findsOneWidget);
    });

    testWidgets('XbNetwork → 重试按钮可见', (t) async {
      await pump(t, const XbViewError(XbNetwork(NetworkErrorKind.timeout, 'x')),
          onRetry: () {});
      expect(find.textContaining('网络异常'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
    });

    testWidgets('XbServer(空 message) → 服务异常 + 重试', (t) async {
      await pump(t, const XbViewError(XbServer(503, '')), onRetry: () {});
      expect(find.textContaining('服务异常'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
    });

    testWidgets('XbServer(有 message) → 透传后端文案', (t) async {
      await pump(t, const XbViewError(XbServer(503, '后端维护中')),
          onRetry: () {});
      expect(find.textContaining('后端维护中'), findsOneWidget);
    });

    testWidgets('XbSecurity → 安全连接失败（无重试）', (t) async {
      await pump(t, const XbViewError(XbSecurity('')), onRetry: () {});
      expect(find.textContaining('安全连接失败'), findsOneWidget);
      expect(find.text('重试'), findsNothing);
    });

    testWidgets('XbUnexpected(空 message) → 出错了 + 重试', (t) async {
      await pump(t, const XbViewError(XbUnexpected('op', '')), onRetry: () {});
      expect(find.textContaining('出错了'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
    });

    testWidgets('XbBusiness(generic + 后端 message) → 透传后端文案', (t) async {
      await pump(
          t,
          const XbViewError(
              XbBusiness(BusinessErrorKind.generic, '邮箱或密码错误', null)),
          onRetry: () {});
      expect(find.textContaining('邮箱或密码错误'), findsOneWidget);
      expect(find.text('操作失败，请稍后重试'), findsNothing);
    });
  });
}
