# 构建与版本管理（形态 A / MyClient / brand_a）

MyClient 的版本号、debug/release 构建方式。**当前为本地构建**（开发期，本地服务器够快，
暂不上 GitHub CI）。目标：版本可追溯、能正确覆盖更新、debug 与 release 不混淆。

---

## 1. 版本号（与 FlClash 底座脱钩，MyClient 自有）

| 项 | 来源 | 说明 |
|---|---|---|
| **versionName** | `flavors/brand_a/flavor.yaml` 的 `versionName`（如 `0.0.1`） | MyClient 产品版本，语义化 `v0.0.1 / v0.0.2 / ...`，功能发布手动递增。**不再用 FlClash 的 0.8.93** |
| **versionCode** | `scripts/build_number.txt` | 整数，每次 **release** 构建脚本自动 +1（单调递增，Android 靠它判定升级/覆盖） |
| **buildTag** | 构建时间戳 `YYYYMMDDHHMM`（如 `202606071230`） | 关于页显示,简洁有意义、每次构建必变（核对编译产物是否最新,防构建缓存复用旧码） |

关于页（我的 → 关于 / 设置 → 关于）显示：`v0.0.1-202606071230`

> `pubspec.yaml` 的 `version:` 仅作 plain `flutter build` 的兜底默认（已设 `0.1.0+1`）；
> 正式构建一律走 `scripts/build_local.sh`，用 `--build-name`/`--build-number` 覆盖。

### ⚠️ AES key 自动注入（本地自测）
`flavor.yaml` 按设计不存密钥（D58，绝不入 git），`prepare_flavor.dart` 生成的
`flavor_defines.json` 里 `XB_AES_KEY_B64` 恒为空。**没有 key → bootstrap 无法解密 config.json
→ 拿不到真实 API 地址 → 登录打到 COS 桶报 `MethodNotAllowed`**。

`build_local.sh` 已内置：构建前从 gitignored 的 `.secrets/xboard-dev-secrets.md` 提取真实
32 字节 base64 主密钥，注入 `flavor_defines.json` 的 `XB_AES_KEY_B64`。所以**即便手动跑过
`prepare_flavor` 把 key 冲空，下次 `build_local.sh` 会自动补回**，无需手工维护。
CI 环境无 `.secrets/`，靠 CI secrets 注入（不受影响）。

### 发布新版本
1. 改 `flavors/brand_a/flavor.yaml` 的 `versionName`（如 `0.0.1` → `0.0.2`）。
2. `bash scripts/build_local.sh release arm64` —— versionCode 自动 +1。

---

## 2. Debug vs Release

| 维度 | Debug | Release |
|---|---|---|
| 用途 | 开发自测、模拟器、看日志 | 真机分发 |
| 命令 | `bash scripts/build_local.sh debug` | `bash scripts/build_local.sh release arm64` |
| 包名 | `com.follow.clash.dev` | `com.follow.clash` |
| 签名 | debug 签名 | release keystore（缺则回退 debug 签名 + `.dev` 后缀） |
| 日志 | `print`/`debugPrint` 可见 | 裁剪 |
| ABI | 全 ABI（模拟器可跑） | split-per-abi（arm64 真机 / x64 模拟器） |
| versionCode | 沿用当前计数（不自增） | 自增 +1 |

> Debug 与 Release **包名不同**（`.dev` 后缀），可在同一台手机共存，互不覆盖。

---

## 3. ⚠️ 构建缓存铁律

Flutter 增量缓存（`.dart_tool/flutter_build`）在 release AOT 构建时可能复用陈旧 `app.dill`，
导致**代码改动未编译进包**（表现：改了 UI/版本但 release 包仍是旧的）。
`scripts/build_local.sh` 已内置每次 `flutter clean`（彻底,比只删 flutter_build 可靠），无需手动处理。

---

## 4. 本地构建

```bash
# Release（真机，arm64；versionCode 自增）
bash scripts/build_local.sh release arm64

# Release x64（模拟器跑 release）
bash scripts/build_local.sh release x64

# Debug（全 ABI，模拟器自测，versionCode 不变）
bash scripts/build_local.sh debug
```

产物在 `build/app/outputs/flutter-apk/`，脚本末尾打印 versionName/versionCode/buildTag。

---

## 5. 分发与覆盖更新

- 本地构建产物拷到下载服务（`/root/projects/.tmp/apk_download/`）供真机下载。
- versionCode 单调递增 → 新版可直接覆盖旧版（无需卸载），**除非**装过早期 versionCode
  畸大的历史包（`2026052901` 那批），那种需卸载一次。
- 真机装后「我的 → 关于」核对 buildTag 是否与本次构建一致。

---

## 6. 上 GitHub CI（v0.x 开发完成后再启用）

开发稳定后可加 `release.yml`（tag 触发签名 release）。届时 versionCode 可改用
`github.run_number`，versionName 仍取 flavor.yaml。当前**不启用**。
