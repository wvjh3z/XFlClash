# test/_fixtures — 全工程共享测试夹具（μ-4）

> 关联：`.kiro/specs/xboard-mvp-form-b/design.md` §C「测试 fixture 共享方案」+ 决策 #9。
> 所有反腐层（W2）/ provider / 页面（W3-W9）测试都从这里取 fake，**不各自重复造**。

## 文件清单

| 文件 | 作用 | 关联 |
|---|---|---|
| `fake_xboard_sdk.dart` | fake `XBoardSDK` + 11 sub-API fake + `setupFor(XbScenario)` 4 场景预设 | 决策 #9 / W0.3 |
| `fake_token_storage.dart` | 内存 `TokenStorage`（`MemoryTokenStorage` 同款） | D63 / F81 / F277 |
| `fake_secure_storage.dart` | fake `FlutterSecureStorage` + Linux 降级模拟 | ζ1 / NFR-3 |
| `fake_connectivity.dart` | fake `connectivity_plus` + 可控网络流 | DD-5 / R11 / R15 |
| `golden_baseline/` | a11y golden test 基准 PNG（W9.4 产出） | 合规 §D / ι-1 |

## 使用规约

### 反腐层测试（注入 fake SDK）

```dart
import '../_fixtures/fake_xboard_sdk.dart';

final sdk = FakeXBoardSDK();
final apis = sdk.setupFor(XbScenario.loggedIn);
// 按 case 细化某个 sub-API 的桩：
when(() => apis.subscriptionApi.getSubscribe()).thenAnswer((_) async => ...);
final service = XboardServiceImpl(sdk: sdk);  // 决策 #9 构造器注入
```

### 4 个场景预设（`XbScenario`）

- `loggedIn` —— isInitialized=true / isAuthenticated=true / 有 Bearer token
- `loggedOut` —— 已初始化但无 token
- `firstLaunch` —— 首次安装态（无 token，配合 firstLaunchProvider 测试）
- `tokenExpired` —— 有过期 token，本地态按未认证（401 后清）

### 存储 / 网络 fake

```dart
final storage = FakeSecureStorage();                       // 正常内存模式
final degraded = FakeSecureStorage(simulateLinuxFailure: true); // ζ1 降级路径

final conn = FakeConnectivity();
conn.goOffline();   // 推 none → 触发离线 banner / 首次离线 splash
await conn.close(); // 测试结束释放
```

## 🔴 实施期 spec 订正（W0.3）

design §C 原写 fake `extends XBoardSDK with Mock`，实测**不可编译**：`XBoardSDK` 是私有
构造（`XBoardSDK._internal()`）+ 全 concrete getter（每个调 `_checkInitialized()`），mixin
无法覆盖 concrete getter，私有构造也跨库不可 extend。改用 SDK 自身测试既有的
`class FakeX extends Mock implements X {}` 模式（见 `Xboard_sdk/test/adapters/xboard/auth_adapter_test.dart`）。
此订正已回写 design §C。
