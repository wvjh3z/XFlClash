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
- W0 基础设施：客户端经 sibling path 依赖 `flutter_xboard_sdk`（接缝点 #3）+ cryptography / sentry_flutter / flutter_secure_storage / qr_flutter / flutter_html 5 包
- 工程基础设施：`.githooks/`（commit-msg `[xfork]` 强制 + pre-commit 行号锚点校验）/ `tool/prepare_flavor.dart`（flavor 校验器）/ `tool/check-line-anchors.dart`（DD-21 接缝点漂移校验）/ `test/_fixtures/`（共享 fake）/ `flavors/brand_a/`（flavor 模板）
- 账号信息卡：显示完整邮箱（用户自己账号不脱敏）+ 套餐到期/流量重置完整展示 + 「购买套餐」「我的订单」入口磁贴
- 账号卡流量用量 ≥90% 提示「购买流量重置包」+ 一键进流量重置包购买页（`reset_traffic_page`）
- 套餐购买三段式流程：列表瘦身卡 → 详情页（flutter_html 渲染 content 富文本 + 周期选择 + 优惠码）→ 提交订单 → 支付页（支付方式 + 立即支付/取消/检测状态 + pending/processing 自动轮询 5s + 手动）
- Bootstrap W5 异步阶段接通：远端镜像拉取 + API/订阅 endpoint 竞速 + baseUrl 热替换（接缝点 #1.bis）
- Bootstrap 服务端响应宽容解析：BOM 剥离 / JSON 字段别名 / 裸 base64（含 PEM 分行/URL-safe）/ JSONP / HTML 包裹 / 重定向跟随 / 瞬时超时重试
- flavor 配置经 dart-define 编译期常量接通 bootstrap（`flavor_defines.json` CI 注入 aesKey/sentryDsn，committed 代码恒可编译）
- brand_a 占位品牌图标 + 应用标签（Gradle flavor sourceSet 覆盖，接缝点 #4.ter）
- 统一错误文案解析 `util/error_text.dart`（`resolveErrorText`）：全链路透传后端真实 message

### Changed
- 流量重置包移出常规套餐购买流程（下单页周期网格 + 列表最小价均过滤 resetTraffic），改由账号卡按需触发
- Bootstrap TLS 证书全放行（用户知情 override θ-1，与 FlClash 上游一致；明网 MITM 风险见 `SECURITY.md`）
- Bootstrap endpoint URL 规范化（去末尾斜杠，解 `/omo//api/v1` 双斜杠拼接）

### Fixed
- 登录/全链路错误：后端真实 message（如「邮箱或密码错误」「套餐周期错误」）不再被吞成兜底「操作失败，请稍后重试」
- 双仪表盘 Tab：`PageLabel.xboard` 唯一寻址修复「我的服务」入口（接缝点 #6 / 决策 #8 修订 a）
- 套餐详情/订单支付页 pushed 到 root navigator 丢失品牌主题 → 包 `XbBrandTheme` 修复品牌红
- a11y：套餐详情页周期卡 2.0 缩放溢出（Wrap 布局）+ dark 模式次按钮对比度（中性前景）

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
