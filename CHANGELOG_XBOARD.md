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

> 开发中累积（尚无正式 release）；首个真实用户 release 时切走为 `## [x.y.z] — YYYY-MM-DD`。
> 当前底座：**FlClash v0.8.93**（upstream `ac2f6b9`）。
> 注：早期按形态 B（v0.1）规划，实际已演进到**形态 A 商业 UI**（唯一 UI）+ v0.2 加密订阅 / Crisp + v0.3 自更新均累积于此 [Unreleased]。产品版本号最终切走时再定（见 conventions §2.8）。

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

#### 形态 A 商业 UI（spec `xboard-form-a-ui-revamp`，现为唯一 UI）
- 自定义三 Tab 外壳（首页 / 节点 / 我的）接管首屏（接缝点 #9 `application.dart` home 替换），大量复用 FlClash 内核 + 形态 B `lib/xboard/` 经 `shell/adapters/` 收口
- 首页：连接球四态（复用 `StartButton`/`coreStatus`）+ 实时速度卡 + 代理模式「智能/全局」切换（隐藏直连）+ 连接/线路/IP 卡
- 节点页：线路分组 / 单节点选择 / 空态 / 游客态；我的页：账号卡 + 续费/购买入口 + 设置（复用 FlClash `ToolsView`）
- 渐进登录 sheet：登录 / 注册 / 忘记密码（邮箱白名单后缀 + 验证码 + gate `bootstrapReadyProvider`，游客优先）
- 桌面端 UI 全面对齐原型 + 桌面标题栏品牌主题统一（接缝点 #11 `window_manager.dart`）

#### v0.2 在线客服 + 加密订阅链路（spec `xboard-mvp-v02-enhancements`）
- 在线客服（Crisp，R1）：Android 原生 SDK + 桌面 WebView（接缝点 #1.ter `desktop_webview_window`）；反腐层 `crisp_support_service.dart`，flavor 级 WEBSITE_ID
- 加密订阅链路（R4）：SDK 文件化订阅（客户端自拉密文 → 复用 bootstrap AES-GCM 解密 → `Profile.saveFile` 写明文 YAML 喂 FlClash 核心，零改上游）；后端插件 `EncryptedSubscribe` 绕 IpAuth 强制 ClashMeta
- 抗封锁加固：endpoint 地区感知竞速 + 订阅 failOver（R4.2/R4.9）/ `next_bootstrap_urls` 地址自举（R4.7）/ 手动导入应急 config 救援通道（R4.8，`bootstrap_manual_import.dart`）
- API/订阅/config.json 全链路浏览器 UA 伪装（R4.4，SDK `allowNonFlclashUa` opt-out + `config/xboard_user_agent.dart`）

#### v0.3 客户端自更新（spec `xboard-mvp-v03-self-update`）
- 版本检查走 Xboard guest 接口 `/api/v1/guest/app/version`（免登录，反腐层 `AppUpdateApi`，照 NoticeApi 分层永不抛）+ 冷启动/进前台 30 分钟节流 + 「我的→关于」手动检查
- 多源下载（`{url, region}` 多镜像）+ sha256 校验 + Android 档1（跳浏览器）/ 档2（应用内下载 + 系统安装器，接缝点 #4.quater `ApkInstallerPlugin` + FileProvider）
- 桌面应用内自更新（Windows .exe / Linux AppImage）

### Changed
- **形态 A 取代形态 B 成为唯一 UI**：回退 FlClash 侧栏注入（接缝点 #5/#6 / `PageLabel.xboard`），改由自定义三 Tab 外壳接管首屏（接缝点 #9）
- formA 屏蔽 FlClash 上游更新检查（接缝点 #10 `action.dart` autoCheckUpdate）：MyClient 自有版本号 + v0.3 自更新，不再弹「发现 FlClash 新版本」
- 接缝点 #7 改用途：撤销 globalUa 强制注入（v0.2 UA 解耦），改为「首次默认开 IPv6」
- 流量重置包移出常规套餐购买流程（下单页周期网格 + 列表最小价均过滤 resetTraffic），改由账号卡按需触发
- Bootstrap TLS 证书全放行（用户知情 override θ-1，与 FlClash 上游一致；明网 MITM 风险见 `SECURITY.md`）
- Bootstrap endpoint URL 规范化（去末尾斜杠，解 `/omo//api/v1` 双斜杠拼接）
- **管理流量证书放行统一为单一策略**（`XboardReleaseHttp` SSoT）：原仅 release dio（config.json/订阅/更新下载）放行证书，现 **SDK API 通道（登录/注册/账号/套餐/订单/支付/版本检查）也证书放行**。可用性优先（裸 IP endpoint 可达，接受 MITM 风险，见 `SECURITY.md`）；UA 伪装 + 直连两条通道同源。SDK 加 `HttpConfig.allowBadCertificate`（v1.18.0）。

### Fixed
- 登录/全链路错误：后端真实 message（如「邮箱或密码错误」「套餐周期错误」）不再被吞成兜底「操作失败，请稍后重试」
- 双仪表盘 Tab：`PageLabel.xboard` 唯一寻址修复「我的服务」入口（接缝点 #6 / 决策 #8 修订 a）
- 套餐详情/订单支付页 pushed 到 root navigator 丢失品牌主题 → 包 `XbBrandTheme` 修复品牌红
- a11y：套餐详情页周期卡 2.0 缩放溢出（Wrap 布局）+ dark 模式次按钮对比度（中性前景）
- **桌面自更新健壮性**：① Linux AppImage 自替换改「同目录 stage 文件 + 原子 `rename`」，避免直接覆盖运行中可执行文件触发 `ETXTBSY`；② 桌面 ABI 真实检测（Windows 读 env / Linux·macOS 跑 `uname -m`），原硬编码 `x64` 会让 arm64 桌面拿错包；③ 更新下载复用放行 dio（UA 伪装 + 证书放行），原用裸 `Dio`
- 知识库正文暗色模式可读性：整页 HTML 以浅色模式硬编码深色文字（`color:#111827` 等），暗底下几乎不可见。`htmlRenderableBody` 对**无自带背景**的元素剥掉 `color` 声明回退主题自适应文字色，**自带背景**的彩色框（警告框/按钮）原样保留；并清除 flutter_html 无法解析的 `var(...)`

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
