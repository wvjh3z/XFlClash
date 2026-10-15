# Xboard 客户端产品 CHANGELOG

> **本文件是 XFlclash「产品」变更记录**，当前为形态 A「首页 / 节点 / 我的」商业客户端。
> 与上游 `CHANGELOG.md`（FlClash 自身发版）分开维护；同步上游时保留本 fork 的产品记录。
>
> **版本号**：产品版本走自己的 SemVer，与上游 FlClash 版本独立递增。
> 产品关于页读取 `XB_PRODUCT_VERSION` / `XB_BUILD_TAG`；原生 `build-name` 保留底座版本，构建号另行注入。`prepare_flavor` 当前不改写 pubspec 为产品与底座的拼接版本。
> **底座版本**：当前为 FlClash v0.8.93；规则、发布流程及已验证批次见 [当前文档](https://github.com/wvjh3z/proxy-suite-docs/blob/main/README.md)。Docs 和 SDK 为私有仓库，需要维护者授予访问权限；旧 `.kiro` 仅作历史追溯，不是开发前置条件。
>
> 格式遵循 [Keep a Changelog](https://keepachangelog.com/)：`Added` 新增 / `Changed` 变更 / `Fixed` 修复 / `Synced` FlClash 底座同步。

## [Unreleased]

> 开发中累积（尚无正式 release）；首个真实用户 release 时切走为 `## [x.y.z] — YYYY-MM-DD`。
> 当前底座：**FlClash v0.8.93**（upstream `ac2f6b9`）。
> 注：早期按形态 B（v0.1）规划，实际已演进到**形态 A 商业 UI**（唯一 UI）+ v0.2 加密订阅 / Crisp + v0.3 自更新，均累积于此 [Unreleased]。下方历史批次编号用于追溯，发布完成度和设备验证以 [STATUS](https://github.com/wvjh3z/proxy-suite-docs/blob/main/STATUS.md) 为准。

> 当前维护决策：D03 订阅孤儿/重复索引暂缓；D06 校验空值行为跟随上游、暂不修复；D04 续费后账号和节点恢复已获用户实测正常，隔离状态边界与设备行为的差异仍待查。本记录不将这些事项列为已修复。

### Fixed
- Sentry 在读取设备上报选择后、Rust 和全局状态初始化之前启动；底座设置 FlutterError 处理器后立即重链，启动降级捕获保留原异常与堆栈。
- Android/Linux 自编原生模块保留调试信息并生成独立伴随文件，核对最终分发文件的 Build ID、调试 ID、行号与展开信息；缺失必要符号时明确失败，调试文件不加入安装包。独立内核进程的崩溃采集仍需另行接入。
- Sentry 增加设备级崩溃上报偏好，启动读取已保存选择；原生平台修改后停止新的业务捕获并提示完全退出重开，使已保存选择生效。按运营要求保留原始事件、面包屑、反馈与标签，恢复原生自动面包屑；SDK 日志保留异常与堆栈。
- Windows 原生模块生成与安装包匹配的独立 PDB；符号上传校验调试 ID、等待处理并明确报告失败，配置日志只显示字段名。
- Windows 教程原生插件采用兼容旧版 VC++ 运行库的 mutex 初始化方式，覆盖插件全部编译单元；补充宏作用域和构建配置回归。
- Windows 教程与客服共用的 WebView2 Loader 在生成安装脚本时解析真实 bundle 目录，修复默认路径残留 CMake 表达式的复制错误；补充默认/显式目录及 Debug/Release 安装回归。
- 教程目录按原型区分空态、失败与超时；空态支持刷新，失败/超时支持重试，短列表与状态页均可下拉。每次目录加载最多等待20秒，旧请求失效后不回填结果、不新启动地址恢复或重发。
- 教程目录接入 KnowledgeList 插件，只下载标题等元数据，点开文章才请求该篇正文；插件不可用时显示错误并允许重试，不回退下载全文目录。
- 桌面客服复用有效窗口，启动和关闭等待增加阶段超时；缺少 WebView2、目录不可写及网络加载失败分别提示，Windows 缺运行组件时可打开微软官方下载页。
- Windows 在线客服显式使用当前用户 LocalAppData 下的持久 WebView2 目录，修复默认安装到 Program Files 后无法创建数据目录的问题。
- Windows 回到前台时接入 Android 同款 24 小时节流刷新：自动重拉共享账号资料并执行既有订阅同步，首页恢复也有效，不依赖 API 地址切换。
- Crisp 升至 3.0.0（Android 原生 2.0.24）；客服打开防连点、等待当前账号资料，异步写入与重置按会话串行。Windows/macOS 客服窗口补充关闭清理、加载失败提示与离线退出后的会话重置，移除错误的运营后台浏览器兜底。
- 订阅在登录前装入完整地区候选；真实下载按地区限并发竞速、保留中国地址兜底预算，网络失败最多自动重试两次，成功地址记忆与会话取消接线，增加脱敏阶段诊断。保留手动刷新 60 秒冷却。

### Added
- 教程正文在 Android、Windows、macOS 使用页面内 WebView，保留原文标题、样式和响应式排版，支持完整值复制、页内跳转及图片放大；外链和下载交系统浏览器。目录只展示「官方客户端」分类，并显示后端文章标题。
- 教程图片等相对资源支持独立源站配置 `tutorialBaseUrl`；Windows 阅读器使用用户可写独立目录，增加运行时检查、加载超时和环境释放兼容适配，与客服统一打包 WebView2 Loader。Linux保留Flutter HTML回退，平台验收范围见当前 STATUS。
- 我的与节点内容区支持下拉刷新，分别与本页标题刷新按钮共用业务方法、忙碌状态及 60 秒冷却；节点空态与短内容也可下拉。两页冷却独立，24 小时前台刷新规则保持原有机制。
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
- 版本检查走 Xboard guest 接口 `/api/v1/guest/app/version`（免登录，由 SDK `AppUpdateApi` 适配）+ 冷启动与前台自动检查 + 「我的→关于」手动检查；不同入口的实际节流和失败边界见 [更新机制](.github/UPDATE_MECHANISM.md)。
- 多源下载（`{url, region}` 多镜像）+ sha256 校验 + Android 档1（跳浏览器）/ 档2（应用内下载 + 系统安装器，接缝点 #4.quater `ApkInstallerPlugin` + FileProvider）
- 桌面应用内自更新（Windows .exe / Linux AppImage）

### Changed
- 桌面 WebView 插件固定升级至 0.3.2，纳入 Windows 导航修复及 macOS 构建/布局修复；客服外链分流仍留待独立适配。
- 支付页手动检测显示转圈、禁用重复操作及分状态提示；「处理中」改为「开通中」，开通中保留检测入口，手机与桌面共用状态逻辑，按页面实际可用宽度切换单列/双栏。
- 首页（移动端/桌面端）和节点列表的延迟数字按原始测速值 ÷ 2 后向下取整展示，界面不增加换算标注；原始结果、测速状态、选优、排序和颜色判断保持原口径。具体契约见 [当前文档](https://github.com/wvjh3z/proxy-suite-docs/blob/main/CONTRACTS.md#延迟测量与显示契约)。
- **形态 A 取代形态 B 成为唯一 UI**：回退 FlClash 侧栏注入（接缝点 #5/#6 / `PageLabel.xboard`），改由自定义三 Tab 外壳接管首屏（接缝点 #9）
- formA 屏蔽 FlClash 上游更新检查（接缝点 #10 `action.dart` autoCheckUpdate）：XFlclash 自有产品版本与更新链，不再弹「发现 FlClash 新版本」
- 接缝点 #7 改用途：撤销 globalUa 强制注入（v0.2 UA 解耦），改为「首次默认开 IPv6」
- 流量重置包移出常规套餐购买流程（下单页周期网格 + 列表最小价均过滤 resetTraffic），改由账号卡按需触发
- Bootstrap TLS 证书全放行（用户知情 override θ-1，与 FlClash 上游一致；明网 MITM 风险见 `SECURITY.md`）
- Bootstrap endpoint URL 规范化（去末尾斜杠，解 `/omo//api/v1` 双斜杠拼接）
- **管理流量证书放行统一为单一策略**（`XboardReleaseHttp` SSoT）：原仅 release dio（config.json/订阅/更新下载）放行证书，现 **SDK API 通道（登录/注册/账号/套餐/订单/支付/版本检查）也证书放行**。可用性优先（裸 IP endpoint 可达，接受 MITM 风险，见 `SECURITY.md`）；UA 伪装 + 直连两条通道同源。SDK 加 `HttpConfig.allowBadCertificate`（v1.18.0）。

### Fixed
- Windows 安装器默认勾选“创建桌面快捷方式”，首次安装及覆盖安装均使用此默认值，用户仍可手动取消。
- 当前认证会话失效后统一清理旧账号订阅/缓存并回到「我的」游客入口，只提示一次登录过期；手工 Profile 保留。只停用当前被清理的账号 Profile，新账号开始同步前等待旧清理完成。
- SDK/客户端按会话 revision 隔离旧请求、重试、订单缓存和凭据条件保存/清除；旧登录弹窗失败与旧节点/账号刷新结果不再覆盖新账号。登录凭据保存失败返回失败；失败的 Profile 清理保留索引并记录诊断。详见 [认证会话契约](https://github.com/wvjh3z/proxy-suite-docs/blob/main/CONTRACTS.md#认证会话与失效事件)。
- 支付页窗口缩放时不再重复写入 late final 容器而报错；扣除桌面侧栏后按剩余宽度排布。「我的」账号卡流量数字与总量可换行，避免内容刚进入双栏时横向溢出，数值与字号保持原规则。
- 支付页取消不再触发到账订阅刷新；详情查询合并在途请求并隔离旧响应，支付返回后读取最新详情，完成刷新按订单/登录上下文去重；首次加载失败后重试成功清除错误。扫码弹窗保留静默轮询并明确二维码尺寸，查询失败保留原订单状态。
- 分组测速在超时重试期间持续显示测速中，成功或最多三次失败后才显示最终延迟/超时，消除中间超时闪现；同名节点的并行测速分别计数，避免首页测速提前结束分组的转圈状态。
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
