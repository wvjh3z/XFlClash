# 构建与版本管理规范（形态 A / brand_a）

本文档定义 **MyClient（XFlClash formA）** 的版本号规则、debug / release 构建方式、
以及 GitHub Actions 自动构建发布流程。目标：**任何人、任何时候构建出的包，版本可追溯、
能正确覆盖更新、debug 与 release 不混淆。**

---

## 1. 版本号规则（单一事实来源）

版本号唯一来源：**`pubspec.yaml` 的 `version:` 字段**，格式 `versionName+versionCode`。

```yaml
version: 0.8.93+100        # versionName=0.8.93  versionCode=100
```

- **versionName**（`0.8.93`）：展示版本名，语义化（主.次.补丁）。功能发布时手动递增。
- **versionCode**（`100`）：整数，**每次发布必须比上一次大**（Android 靠它判定升级/降级）。
  由 CI 用 **GitHub run number** 自动注入（`--build-number`），开发者不手填，保证单调递增。

> ⚠️ Android versionCode 上限 2,100,000,000。用 run number（从小整数起）永不触顶。

### 历史遗留说明
早期 `version: 0.8.93+2026052901`（日期串当 versionCode，畸大）。已改为小整数基线，
**从该畸大值升级的旧包需卸载一次**；此后所有版本 versionCode 由 CI 递增，正常覆盖。

---

## 2. 构建标识（build tag）

每个包在「我的 → 关于」显示 `v{versionName}+{versionCode} · {buildTag}`。

- `buildTag` 由 `--dart-define=XB_BUILD_TAG=...` 注入，CI 用 `git短SHA + 时间` 生成。
- 作用：一眼确认安装的是不是目标构建（解决"装的是不是新版"的困惑）。
- 本地未注入时为空，关于页只显示 `v{versionName}+{versionCode}`。

---

## 3. Debug vs Release

| 维度 | Debug | Release |
|---|---|---|
| 用途 | 开发自测、模拟器、看日志 | 真机分发、正式发布 |
| 命令 | `flutter build apk --debug` | `flutter build apk --release` |
| 签名 | debug 签名（`.dev` 后缀包名） | release keystore（CI secrets 注入） |
| 包名 | `com.follow.clash.dev` | `com.follow.clash` |
| 日志 | `print`/`debugPrint` 可见 | 裁剪（仅 commonPrint 等保留） |
| ABI | 全 ABI（模拟器可跑） | split-per-abi（arm64 真机） |

> Debug 与 Release **包名不同**（`.dev` 后缀），可在同一台手机共存，互不覆盖。
> 测真机功能装 release；看日志/快速迭代用 debug。

---

## 4. ⚠️ 构建缓存铁律（曾踩坑）

Flutter 增量构建缓存（`.dart_tool/flutter_build`）在 **release AOT 构建时可能复用陈旧
`app.dill`**，导致**代码改动未编译进包**（表现：改了 UI 但 release 包仍是旧界面/旧版本号）。

**规范：release 正式构建前必须清缓存**（CI 在干净 runner 上天然满足；本地脚本已内置）：
```bash
flutter clean    # 或至少 rm -rf .dart_tool/flutter_build build/
```

---

## 5. 本地构建（开发自测）

统一用 `scripts/build_local.sh`（已内置清缓存 + buildTag 注入 + flavor）：

```bash
# Release arm64（真机分发）
bash scripts/build_local.sh release arm64

# Debug 全 ABI（模拟器）
bash scripts/build_local.sh debug
```

产物在 `build/app/outputs/flutter-apk/`，脚本末尾打印 versionName/versionCode/buildTag。

---

## 6. CI 自动构建发布（GitHub Actions）

### 6.1 正式发布 `release.yml`（tag 触发）
推一个 `v*` tag 即触发：
```bash
git tag v0.8.94 && git push origin v0.8.94
```
流程：测试 → prepare_flavor（注入 secrets）→ 清缓存 release 构建（versionCode=run_number，
签名）→ 上传 APK 到 GitHub Release。

### 6.2 测试包 `debug-build.yml`（手动 / PR 触发）
手动触发或 PR 时构建 debug APK，传 artifact 供测试，不发 Release。

### 6.3 所需 Secrets
| Secret | 用途 |
|---|---|
| `KEYSTORE` | release 签名 keystore（base64） |
| `KEY_ALIAS` / `STORE_PASSWORD` / `KEY_PASSWORD` | 签名凭据 |
| `XBOARD_BOOTSTRAP_AES_KEY` | bootstrap/订阅 AES key |
| `SIBLING_SDK_TOKEN` | clone sibling Xboard_sdk |
| `SERVICE_JSON` | google-services.json（base64，可选） |

---

## 7. 发版 checklist
1. 改 `pubspec.yaml` versionName（如 `0.8.94`），versionCode 留给 CI。
2. 更新 CHANGELOG。
3. `git tag vX.Y.Z && git push origin vX.Y.Z`。
4. CI 自动构建签名 release + 发 GitHub Release。
5. 装真机，「我的→关于」核对 `vX.Y.Z+{run} · {buildTag}`。
