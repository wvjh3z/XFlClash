# Xboard 客户端产品 CHANGELOG

> **本文件是 Xboard 客户端「产品」发版记录**（form B：FlClash + 账号侧栏）。
> 与上游 `CHANGELOG.md`（FlClash 自身发版，v0.8.x...）**分开维护** —— 见 conventions §2.8 双轨版本号。
> upstream sync 永远不碰带 `_XBOARD` 后缀的文件（零冲突）。
>
> **版本号**：产品版本走自己的 SemVer，与上游 FlClash 版本独立递增。
> 最终 app 版本号 = `<产品版本>+flclash<底座版本>`（如 `0.1.0+flclash0.8.93`，由 `tool/prepare_flavor.dart` 构建时注入）。
> **底座版本**：当前 fork 的 FlClash upstream tag（见 `.kiro/specs/xboard-mvp-form-b/flclash-anchors.md` 基线 + `.kiro/UPSTREAM_SYNC.md`）。
>
> 格式遵循 [Keep a Changelog](https://keepachangelog.com/)：`Added` 新增 / `Changed` 变更 / `Fixed` 修复 / `Synced` FlClash 底座同步。

## [Unreleased]

> v0.1 开发中累积；首个真实用户 release 时切走为 `## [0.1.0] — YYYY-MM-DD`。
> 当前底座：**FlClash v0.8.93**（upstream `ac2f6b9`）。

### Added
- W0 基础设施：客户端经 sibling path 依赖 `flutter_xboard_sdk`（接缝点 #3）+ cryptography / sentry_flutter / flutter_secure_storage / qr_flutter 4 包
- 工程基础设施：`.githooks/`（commit-msg `[xfork]` 强制 + pre-commit 行号锚点校验）/ `tool/prepare_flavor.dart`（flavor 校验器）/ `tool/check-line-anchors.dart`（DD-21 接缝点漂移校验）/ `test/_fixtures/`（共享 fake）/ `flavors/brand_a/`（flavor 模板）

### Synced
- 底座基线锁定 FlClash **v0.8.93**（upstream `ac2f6b9`）—— 初始同步点，后续 sync 在此追加

---

<!--
模板（每次 release 复制）：

## [0.x.0] — YYYY-MM-DD

当前底座：FlClash vX.Y.Z（upstream <commit>）

### Added
- 用户可见的新功能

### Changed
- 行为变更

### Fixed
- bug 修复

### Synced
- 底座 FlClash vA.B.C → vX.Y.Z（如有；无则省略本组）
-->
