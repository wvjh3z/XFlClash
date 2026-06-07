# 更新机制说明（FlClash 上游更新检查屏蔽 + 未来自更新系统设计参考）

本文档记录:**(A)** 我们如何屏蔽 FlClash 自带的更新检查;**(B)** FlClash 更新链路的完整
拆解,供将来做 MyClient 自己的更新系统时复用。

---

## A. 当前:已屏蔽 FlClash 上游更新检查（接缝点 #10）

### 现象
打开 app 启动时弹「发现新版本 V0.8.93 / 0.9.x」——因为 FlClash 自带更新检查会比对
**上游 FlClash 的 GitHub release**（`chen08209/FlClash`),与 MyClient 无关,误导用户。

### 屏蔽点（最小侵入）
文件:`lib/providers/action.dart` 的 `autoCheckUpdate()`,首行加 formA gate:

```dart
Future<void> autoCheckUpdate() async {
  if (XboardConfig.current.formA) return;   // ← 接缝点 #10:formA 直接跳过
  if (!ref.read(appSettingProvider).autoCheckUpdate) return;
  final res = await request.checkForUpdate();
  checkUpdateResultHandle(data: res);
}
```

formA=true（MyClient）→ 整个更新检查不执行;formA=false（FlClash 原版兜底）→ 行为不变。
登记于 `.kiro/PATCHES.md` 接缝点 #10。

---

## B. FlClash 更新链路完整拆解（做自更新系统的复用基础）

### B.1 触发点
- **启动自动检查**:`lib/state.dart`（约 :312）调
  `container.read(commonActionProvider.notifier).autoCheckUpdate()`。
- **手动检查**:`lib/views/about.dart` 的 `_checkUpdate()` → `request.checkForUpdate()`
  → `commonActionProvider.notifier.checkUpdateResultHandle(data, isUser: true)`。
- 设置开关:`appSettingProvider.autoCheckUpdate`（`lib/models/config.dart` `@Default(true)`），
  UI 在 `lib/views/application_setting.dart`。

### B.2 核心方法（`lib/providers/action.dart`）
- `autoCheckUpdate()`:开关 gate → `request.checkForUpdate()` → `checkUpdateResultHandle`。
- `checkUpdateResultHandle({data, isUser})`:解析返回,有新版 → 弹 dialog;
  「去下载」→ `launchUrl('https://github.com/$repository/releases/latest')`;
  「不再提醒」→ 关 `autoCheckUpdate` 设置;无新版且 isUser → toast「已是最新」。

### B.3 请求层（`request.checkForUpdate()`，`lib/common/request.dart` :73）
- 拉 **`https://api.github.com/repos/chen08209/FlClash/releases/latest`**（上游仓库,硬编码
  `repository` 常量),比对 tag 与本地 `globalState.packageInfo.version`。
- `repository` 常量:`lib/common/constant.dart` :59 `const repository = 'chen08209/FlClash';`。

### B.4 版本比较
- 用 `globalState.packageInfo.version`（= pubspec/`--build-name`,我们已是 MyClient 0.0.x）
  与 GitHub tag 的语义版本比较。
- ⚠️ 我们的 versionName（0.0.1）远小于 FlClash（0.8.93）→ 必然判定"有新版"→ 这就是误弹根因。

---

## C. 未来做 MyClient 自更新系统的建议

> 目标:MyClient 检查**自己的**发布源,而非 FlClash;直接装 APK 或跳转下载。

### C.1 复用 vs 新建
- **推荐新建**,放 `lib/xboard/`（隔离层,不碰上游）。不要改 FlClash 的 `checkForUpdate`,
  保持接缝点 #10 屏蔽上游那套。
- 可参考 FlClash 的 dialog/launchUrl 交互（`checkUpdateResultHandle`）作为 UI 范式。

### C.2 后端来源（与 bootstrap 体系一致最省事）
MyClient 已有加密 bootstrap config 体系(`lib/xboard/services/bootstrap_*`,AES-GCM)。
建议把更新信息也放进 bootstrap config / 一个新的版本接口:
```
{
  "latest_version": "0.1.0",
  "latest_build": 42,
  "min_supported_build": 10,        // 低于此强制更新
  "apk_url": "https://.../MyClient-0.1.0.apk",
  "changelog": "...",
  "force": false
}
```
- 复用 `EndpointRaceController` 的竞速 + failOver(更新源也可多 endpoint)。
- 复用 `BootstrapDecryptor`(同一 AES key/nonce,换 AAD,如 `xboard-update-v1`)。

### C.3 版本比较口径
- 用 **versionCode（build number,整数）** 比较,不要用 versionName 字符串(易错)。
  本地 build 号:`PackageInfo.fromPlatform().buildNumber`。
- 服务端给 `latest_build`;`本地 build < latest_build` → 有更新。
- `本地 build < min_supported_build` → 强制更新(拦在登录前)。

### C.4 安装方式（Android）
- 应用内下载 APK → `OpenFilex`/intent 触发系统安装器(需 `REQUEST_INSTALL_PACKAGES` 权限)。
- 或跳浏览器下载页(最简单,无需新权限)。
- versionCode 必须 > 当前(见 `.github/BUILD_AND_RELEASE.md` 版本规则),否则系统判降级拒装。

### C.5 触发时机
- 冷启动 bootstrap 完成后查一次(参考 `XboardModule.bootstrapAsync` fire-and-forget 模式)。
- 复用 `SubscriptionTriggers` 的 24h 节流思路,避免每次启动都弹。

### C.6 接入点
- 在 `lib/xboard/shell/xboard_app_shell.dart` 的 `initState` 或 bootstrap 异步阶段触发自更新检查。
- UI 用形态 A 组件(`XbStatusCard`/`xbShowDialog`),与全局设计语言一致。

---

## D. 相关文件索引
| 关注点 | 文件 |
|---|---|
| 上游更新屏蔽 gate | `lib/providers/action.dart` `autoCheckUpdate()` |
| 上游更新逻辑 | `lib/providers/action.dart` `checkUpdateResultHandle()` |
| 上游请求 | `request.checkForUpdate()`（grep `checkForUpdate`） |
| 启动触发 | `lib/state.dart`（约 :312） |
| 手动检查 UI | `lib/views/about.dart` `_checkUpdate()` |
| 设置开关 | `lib/views/application_setting.dart` / `lib/models/config.dart` |
| 版本号规则 | `.github/BUILD_AND_RELEASE.md` |
| 加密 bootstrap 基建(可复用) | `lib/xboard/services/bootstrap_*.dart` |
