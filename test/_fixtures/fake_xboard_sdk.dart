/// 全工程共享 fake `XBoardSDK` — 所有反腐层 / provider 测试用此。
///
/// **关联**：design §C「测试 fixture 共享方案（μ-4）」+ 决策 #9（反腐层注入式构造）。
///
/// **🔴 实施期 spec 订正（W0.3）**：design §C 原写 `extends XBoardSDK with Mock`，
/// 但 `XBoardSDK` 是私有构造（`XBoardSDK._internal()`）+ 全 concrete getter（每个调
/// `_checkInitialized()`），无法 `with Mock` 混入（mixin 不能覆盖 concrete getter，
/// 且私有构造跨库不可 extend）。改用 SDK 自身测试既有的 `extends Mock implements X`
/// 模式（见 `Xboard_sdk/test/adapters/xboard/auth_adapter_test.dart`）—— mocktail 对
/// `implements` 生成 noSuchMethod 桩，11 个 sub-API getter 全可 stub。
///
/// 反腐层生产端从 `xboardSdkProvider` 读真 `XBoardSDK.instance`，测试端注入本 fake
/// （`XboardServiceImpl(sdk: FakeXBoardSDK()..stubLoggedIn())`）。
library;

import 'package:flutter_xboard_sdk/flutter_xboard_sdk.dart';
import 'package:mocktail/mocktail.dart';

/// fake 顶层入口。`extends Mock implements XBoardSDK` —— 全成员经 mocktail noSuchMethod。
class FakeXBoardSDK extends Mock implements XBoardSDK {}

/// 11 个 sub-API 接口的 fake（与 SDK barrel 导出的接口一一对应）。
class FakeAuthApi extends Mock implements AuthApi {}

class FakeUserApi extends Mock implements UserApi {}

class FakePlanApi extends Mock implements PlanApi {}

class FakeOrderApi extends Mock implements OrderApi {}

class FakeSubscriptionApi extends Mock implements SubscriptionApi {}

class FakeInviteApi extends Mock implements InviteApi {}

class FakeIpMirrorApi extends Mock implements IpMirrorApi {}

class FakeNoticeApi extends Mock implements NoticeApi {}

class FakeTicketApi extends Mock implements TicketApi {}

class FakeConfigApi extends Mock implements ConfigApi {}

class FakePaymentApi extends Mock implements PaymentApi {}

/// 常用测试场景预设（design §C「setupFor(Scenario) 工厂」）。
enum XbScenario {
  /// 已登录：isInitialized=true、isAuthenticated=true、authState=authenticated。
  loggedIn,

  /// 未登录：isInitialized=true、isAuthenticated=false、authState=unauthenticated。
  loggedOut,

  /// 首次安装：isInitialized=true、无 token、authState=unauthenticated。
  firstLaunch,

  /// token 过期：isInitialized=true、有过期 token、authState=unauthenticated。
  tokenExpired,
}

/// 给 [FakeXBoardSDK] 套上一组与场景一致的桩。
///
/// 用法：
/// ```dart
/// final sdk = FakeXBoardSDK();
/// final apis = sdk.setupFor(XbScenario.loggedIn);
/// // apis.authApi / apis.userApi ... 可继续按测试 case 细化 when() 桩
/// final service = XboardServiceImpl(sdk: sdk);
/// ```
extension FakeXBoardSDKSetup on FakeXBoardSDK {
  FakeSubApis setupFor(XbScenario scenario) {
    final apis = FakeSubApis();

    // 11 个 sub-API getter 全部回 fake（懒加载语义无关，每次回同一实例）
    when(() => auth).thenReturn(apis.authApi);
    when(() => user).thenReturn(apis.userApi);
    when(() => plan).thenReturn(apis.planApi);
    when(() => order).thenReturn(apis.orderApi);
    when(() => subscription).thenReturn(apis.subscriptionApi);
    when(() => invite).thenReturn(apis.inviteApi);
    when(() => ipMirror).thenReturn(apis.ipMirrorApi);
    when(() => notice).thenReturn(apis.noticeApi);
    when(() => ticket).thenReturn(apis.ticketApi);
    when(() => config).thenReturn(apis.configApi);
    when(() => payment).thenReturn(apis.paymentApi);

    // SDK 生命周期 / 认证态桩
    when(() => isInitialized).thenReturn(true);

    switch (scenario) {
      case XbScenario.loggedIn:
        when(() => isAuthenticated).thenReturn(true);
        when(() => authState).thenReturn(AuthState.authenticated);
        when(() => authStateStream)
            .thenAnswer((_) => Stream.value(AuthState.authenticated));
        when(getToken).thenAnswer((_) async => 'Bearer fake-auth-token');
        when(hasToken).thenAnswer((_) async => true);
      case XbScenario.loggedOut:
      case XbScenario.firstLaunch:
        when(() => isAuthenticated).thenReturn(false);
        when(() => authState).thenReturn(AuthState.unauthenticated);
        when(() => authStateStream)
            .thenAnswer((_) => Stream.value(AuthState.unauthenticated));
        when(getToken).thenAnswer((_) async => null);
        when(hasToken).thenAnswer((_) async => false);
      case XbScenario.tokenExpired:
        // 有 token 但后端会判过期；本地态先按未认证（401 后清）
        when(() => isAuthenticated).thenReturn(false);
        when(() => authState).thenReturn(AuthState.unauthenticated);
        when(() => authStateStream)
            .thenAnswer((_) => Stream.value(AuthState.unauthenticated));
        when(getToken).thenAnswer((_) async => 'Bearer expired-token');
        when(hasToken).thenAnswer((_) async => true);
    }

    return apis;
  }
}

/// 11 个 sub-API fake 的容器，测试可按需细化各自的 `when()` 桩。
class FakeSubApis {
  final FakeAuthApi authApi = FakeAuthApi();
  final FakeUserApi userApi = FakeUserApi();
  final FakePlanApi planApi = FakePlanApi();
  final FakeOrderApi orderApi = FakeOrderApi();
  final FakeSubscriptionApi subscriptionApi = FakeSubscriptionApi();
  final FakeInviteApi inviteApi = FakeInviteApi();
  final FakeIpMirrorApi ipMirrorApi = FakeIpMirrorApi();
  final FakeNoticeApi noticeApi = FakeNoticeApi();
  final FakeTicketApi ticketApi = FakeTicketApi();
  final FakeConfigApi configApi = FakeConfigApi();
  final FakePaymentApi paymentApi = FakePaymentApi();
}
