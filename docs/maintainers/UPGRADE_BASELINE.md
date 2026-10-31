# 当前升级对照基线与功能归属

用途：把我们两个品牌客户端的行为与**原版FlClash v0.9.2固定提交**对应，升级时按影响链查要求、实现、接缝与回归。流程唯一维护在[UPGRADING](UPGRADING.md)；接缝真源是[PATCHES](https://github.com/wvjh3z/proxy-suite-docs/blob/main/PATCHES.md)和[FLCLASH_ANCHORS](https://github.com/wvjh3z/proxy-suite-docs/blob/main/FLCLASH_ANCHORS.md)，实际结果唯一见[STATUS](https://github.com/wvjh3z/proxy-suite-docs/blob/main/STATUS.md)。本表不代表所有行为均已设备验收。品牌/SDK链接用于当前源码导航，复现本轮结论须检出下表冻结提交；原版链接固定v0.9.2提交。

## 基线身份

2026-10-30只读代码核对；本轮只改文档。当前受Git管理的下表记录冻结审计输入，当前实现须结合后续变更核对，工作区另有已说明的文档更正和Core CA脏文件，不纳入本表为新行为。

| 对象 | 冻结对照／真源 | 边界 |
| --- | --- | --- |
| 当前维护分支 | 三仓main | 升级分支保留历史，不作为默认操作入口 |
| 冻结审计时品牌客户端 | `dd61c4e9884b8bbd4d5b5d06b67ff1797523f429` | 仅该冻结点的运行时源码与#144/#146构建源码2959e792一致，非完整Git树一致（文档/CI引用/编号等有差异）；当前main已有后续资源变化，见F19，不代表当前全部实现 |
| 原版FlClash | v0.9.2，`7fd417fb9a9a277c6a9339a8ac87f907df7c25f7` | 下文原版链接固定该commit；不能用品牌HEAD或移动的upstream/main替代 |
| 审计时SDK | `aef9d33525054e09fccaa71ad9cdb480f1f88f39` | 冻结审计输入；当前发行引用读取[release-config.json](../../tool/release-config.json)，不能凭Docs版本猜SDK版本 |
| 审计起点Docs | `2653d9853a1dbab3ffa88cb057b58ec58a6e360d` | 细化前的冻结文档起点；本文随后随main交付，当前CI引用以[xboard-ci.yml](../../.github/workflows/xboard-ci.yml)为准 |
| 原版内核gitlink | `c5062921054902b25215a6a933e72ccd714c9bfa` | `core/Clash.Meta`现有CA脏修改保留；不提交、不用它反推官方源码 |
| 追溯基线 | 原版v0.9.1 `8d4f9744948751f1273fe871e1d05276fac09b0e`；旧品牌v0.8.93 `ae148e64694ab276c35796f95d77f6bbbe25f0d2` | 只追溯历史，不恢复旧工具链，不把旧品牌代码称为原版 |
| 工具和物理路径 | [native_toolchain.json](../../tool/native_toolchain.json)、锁文件、[WORKSPACE](WORKSPACE.md) | active为唯一开发入口；本机upstream/FlClash-v0.9.2是只读便利副本，Git对象是依据，CI不依赖该副本 |

## 分类与证据用法

分类标签采用[UPGRADING的三个原则](UPGRADING.md#先按本项目实际使用方式分类再决定适配)；本表只记录具体功能归类，不重复维护规则。
- “用户要求”只引用已确认产品决定；“维护约束”来自安全重入、数据归属及统一验收，不冒充用户逐字决定；“当前实现”是源码事实；“限制”不应固化成升级后必须保留的行为。
- **F01—F28稳定不改号**，a/b子项用于拆同一功能的层次；S01—S09只是本文的接缝索引组，**不是新接缝、锚点或数量**；P为平台入口，U为未接入，UB-GAP为本表局部缺口，不占用项目已有D/G编号；缺口对应关系与当前状态见[STATUS](https://github.com/wvjh3z/proxy-suite-docs/blob/main/STATUS.md#当前缺口索引)。测试链接仅证明入口存在，本轮不运行Flutter/Dart或构建。
- 关系字段区分**输入/直接调用**与**下游/联查**：后者表示升级影响范围，不宣称页面直接调用彼此；同一个宿主事件的并列消费者也不是串行处理链。
- 下文F项默认适用于**品牌A和品牌B × Android/Windows/macOS/Linux**；平台专属差异必须叠加P表，不以共用代码代替各品牌成品或原生验收。iOS/Windows ARM64只做共享影响分析，不承诺发布。

当前源码的包/相对导入、导出候选及配置/入口清单见[只读依赖报告](https://github.com/wvjh3z/proxy-suite-docs/blob/main/evidence/upgrade-v0.9.2/DEPENDENCY_CONFIG_REACHABILITY.md)。这是报告模式，不能替代符号解析、运行证明或现有禁止规则。

## 主链路逐项对照

| ID | 行为 | 三原则归类 |
| --- | --- | --- |
| [F01](#f01) | 启动、就绪与入口分流 | 自有+复用 |
| [F02](#f02) | Bootstrap、缓存与fallback | 自有 |
| [F03](#f03) | API竞速、换址与异常恢复 | 自有 |
| [F04](#f04) | 物理网络、VPN有效状态与前后台 | 自有接线+复用事件 |
| [F05](#f05) | 登录、登出与会话持久化 | 自有+平台存储依赖 |
| [F06](#f06) | 加密订阅到Profile及内核应用 | 自有下载+复用Profile执行 |
| [F07](#f07) | 套餐、订单和支付 | 自有 |
| [F08](#f08) | 连接、断开、暂停和恢复 | 自有展示+复用执行 |
| [F09](#f09) | 智能／全局模式及入口一致性 | 自有规则+复用模式执行 |
| [F10](#f10) | 节点列表与当前选择 | 自有页面+复用分组/选择 |
| [F11](#f11) | 出口IP探测、调度与显示 | 自有探测+复用网络/路由通知 |
| [F12](#f12) | 节点测速与首页延迟 | 自有调度+复用Core探测 |
| [F13](#f13) | 系统代理、TUN、DNS、IPv6与Geo更新 | 复用执行+自有首次默认/Geo调度 |
| [F14](#f14) | TLS及HTTP代理政策 | 自有业务政策+复用宿主 |
| [F15](#f15) | 更新检查与24小时时窗 | 自有调度/面板版本协议 |
| [F16](#f16) | 下载、安装交接与退出 | 自有更新能力+复用退出/安装器 |
| [F17](#f17) | Crisp客服 | 自有接入+第三方SDK |
| [F18](#f18) | 教程与链接导航 | 自有阅读器+平台WebView |
| [F19](#f19) | 品牌身份、目录、图标及并存 | 自有隔离+复用平台集成 |
| [F20](#f20) | 数据库、旧数据迁移及恢复 | 复用主库+自有归属/有限重试 |
| [F21](#f21) | 主题、字体、设置与界面外壳 | 自有外壳+复用主题/字体 |
| [F22](#f22) | 异常分类、Sentry与符号链 | 自有上报/构建治理+复用错误入口 |
| [F23](#f23) | 底座原生子页及设置恢复 | 复用页面/执行+自有导航 |
| [F24](#f24) | 账号资料刷新与订阅触发 | 自有调度+复用生命周期 |
| [F25](#f25) | 公告、未读与弹窗生命周期 | 自有 |
| [F26](#f26) | 邀请、佣金、提现与分享链接 | 自有 |
| [F27](#f27) | 首页实时流量与速度单位 | 自有展示+复用流量provider |
| [F28](#f28) | 品牌浏览器UA与底座globalUa | 自有HTTP政策+复用底座通用UA |

<a id="f01"></a>
### F01 启动、就绪与入口分流

**缺口关联**：UB-GAP-01/16，当前进度和关闭条件见本文缺口索引所指STATUS。

- **归类／要求**：自有+复用。维护约束：单实例占有先于共享数据写入；首屏就绪、SDK可用与内核可用不能混为同一状态；保留品牌欢迎与上报选择。
- **原版0.9.2**：[lib/main.dart · main](https://github.com/chen08209/FlClash/blob/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7/lib/main.dart)依次准备Rust、system、bootstrap、HttpOverrides；[lib/bootstrap.dart · Bootstrap._initData](https://github.com/chen08209/FlClash/blob/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7/lib/bootstrap.dart)处理迁移、容器和启动恢复。原版没有Xboard同步/异步阶段。
- **当前品牌实现**：[lib/main.dart](../../lib/main.dart)在桌面提前acquire；[lib/bootstrap.dart](../../lib/bootstrap.dart)通过品牌TLS默认协调迁移；[XboardModule.bootstrap/bootstrapAsync](../../lib/xboard/xboard_module.dart)本地初始化与后台远端更新分开；[lib/xboard/providers/xboard_providers.dart](../../lib/xboard/providers/xboard_providers.dart)表示品牌门禁。
- **依赖／平台／接缝**：F01a=桌面单实例，F01b=品牌同步/异步，F01c=原版BootGuard/错误页。启动直接接入F02/F05/F19/F20/F22；就绪变化影响F08/F15。接缝S01/S02。Android另有Service/Activity，桌面另有WebView子进程；按P矩阵验。
- **回归入口与必测分支**：启动异常、无合法fallback、内核未就绪、第二实例、重开恢复分别验证。[test/xboard/bootstrap_sync_phase_test.dart](../../test/xboard/bootstrap_sync_phase_test.dart)、[test/xboard/bootstrap_async_phase_test.dart](../../test/xboard/bootstrap_async_phase_test.dart)、[test/xboard/storage/single_instance_lock_test.dart](../../test/xboard/storage/single_instance_lock_test.dart)。
- **限制／状态**：源码已定位；上述测试存在不等于本轮执行；启动/原生子进程需设备验收，见UB-GAP-01。

<a id="f02"></a>
### F02 Bootstrap、缓存与fallback

- **归类／要求**：自有。用户要求：保留两品牌独立配置/出厂fallback及全局代理继承；维护约束：密文验证失败不得当成有效配置。 决定出处：REQ-NET（见文末）。
- **原版0.9.2**：原版没有品牌Bootstrap或AES配置自举；其通用HTTP在[lib/common/http.dart · FlClashHttpOverrides](https://github.com/chen08209/FlClash/blob/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7/lib/common/http.dart)。不能把原版Profile下载当作相同功能。
- **当前品牌实现**：[loadLocal](../../lib/xboard/services/bootstrap_local_loader.dart)依次读缓存密文、品牌fallback；[lib/xboard/services/bootstrap_decryptor.dart](../../lib/xboard/services/bootstrap_decryptor.dart)验证；[_bootstrapAsyncPhase](../../lib/xboard/xboard_module.dart)后台拉取远端，合并缓存next_bootstrap_urls与品牌bootstrapUrls；失败沿用本地候选。
- **依赖／平台／接缝**：输入为F14网络政策和F19品牌资源；本地阶段供F01启动，候选变化供F03竞速。S01/S06只负责启动/入包，加载解密本身是自有代码。Android assets、桌面data/flutter_assets必须分别读取成品，A包不得含B的fallback。
- **回归入口与必测分支**：缓存坏/缺失、远端坏/超时、fallback缺失/串品牌、异步迟到。[test/xboard/services/bootstrap_local_loader_test.dart](../../test/xboard/services/bootstrap_local_loader_test.dart)、[test/xboard/services/bootstrap_fetcher_test.dart](../../test/xboard/services/bootstrap_fetcher_test.dart)、[tool/check_fallback_assets.py](../../tool/check_fallback_assets.py)。
- **限制／状态**：品牌私密值不写入基线；实际出包与配置顺序证据查STATUS，不能仅凭源码assets声明验收。

<a id="f03"></a>
### F03 API竞速、换址与异常恢复

- **归类／要求**：自有。用户要求：可恢复请求可遍历候选地址，不只换一次；保留业务拒绝语义，HTML不直接显示给用户。维护约束：写操作不能套用读取重放。 决定出处：REQ-API（见文末）。
- **原版0.9.2**：原版不含Xboard API/认证端点池；只依赖[lib/common/http.dart · createHttpClient](https://github.com/chen08209/FlClash/blob/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7/lib/common/http.dart)宿主网络政策。原版节点测速不是API可用性探测。
- **当前品牌实现**：[EndpointRaceController](../../lib/xboard/services/endpoint_race_controller.dart)选择候选，[lib/xboard/sdk/xboard_service_impl.dart](../../lib/xboard/sdk/xboard_service_impl.dart)接SDK；[SDK ApiRecovery.run](https://github.com/wvjh3z/Xboard_sdk/blob/main/lib/src/core/http/api_recovery.dart)按操作策略及错误分类恢复，[HttpService](https://github.com/wvjh3z/Xboard_sdk/blob/main/lib/src/core/http/http_service.dart)维护请求与有效性。
- **依赖／平台／接缝**：F03a=竞速，F03b=真实请求恢复，两者独立；输入为F02候选、F14网络及F05会话有效性，F04提供重竞速触发。下游联查F05/F07/F15/F18等API消费者。底座仅S01网络注入；完整操作白名单见Docs/CONTRACTS，不复制状态码清单。
- **回归入口与必测分支**：403/405网关响应与业务JSON拒绝、候选耗尽、并发切址、换号和取消、写响应不明。[test/xboard/services/endpoint_race_controller_test.dart](../../test/xboard/services/endpoint_race_controller_test.dart)、[test/xboard/services/endpoint_probe_tls_test.dart](../../test/xboard/services/endpoint_probe_tls_test.dart)、[SDK恢复测试](https://github.com/wvjh3z/Xboard_sdk/blob/main/test/core/http/api_recovery_test.dart)。
- **限制／状态**：探测成功不保证某个业务API成功；不能据竞速胜出自动清除所有业务路由故障记录。预算与重新选回故障地址的现状不在文档任务中改写。

<a id="f04"></a>
### F04 物理网络、VPN有效状态与前后台

- **归类／要求**：自有接线+复用事件。用户要求：连接/断开、恢复前台及物理网络变化重新评估API；维护约束：未知网络不能当作已断网，暂停不等于有效VPN。 决定出处：REQ-NET（见文末）。
- **原版0.9.2**：[lib/application.dart · _handleConnectivityChanged](https://github.com/chen08209/FlClash/blob/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7/lib/application.dart)处理宿主网络事件；[lib/providers/route_state.dart · RouteTracker](https://github.com/chen08209/FlClash/blob/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7/lib/providers/route_state.dart)维护路由世代；[lib/providers/actions/setup.dart · syncSuspend](https://github.com/chen08209/FlClash/blob/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7/lib/providers/actions/setup.dart)执行按需暂停。
- **当前品牌实现**：[XboardNetworkObserver](../../lib/xboard/services/xboard_network_observer.dart)以isStart&&!suspend和物理网络集合变化通知竞速；[lib/xboard/providers/xboard_connectivity_provider.dart](../../lib/xboard/providers/xboard_connectivity_provider.dart)提供事件；XboardModule保持跨Tab订阅。
- **依赖／平台／接缝**：输入为F08有效VPN状态和connectivity事件，直接调用F03竞速；VPN有效跃迁还回调F15节流更新及F13b Geo调度。F11是另一条宿主路由事件消费者，不经过本观察器。S01启动接线；物理网络变化不自动刷新全部订阅/API业务。
- **回归入口与必测分支**：重复/乱序网络事件、vpn标签变化、Wi-Fi到移动网、未知/错误事件、暂停恢复、退后台。[test/xboard/services/xboard_network_observer_test.dart](../../test/xboard/services/xboard_network_observer_test.dart)、[test/xboard/services/subscription_triggers_test.dart](../../test/xboard/services/subscription_triggers_test.dart)。
- **限制／状态**：真实Android网络回调和Linux网络服务可用性另验；Widget替身不能证明系统实际发出了事件。

<a id="f05"></a>
### F05 登录、登出与会话持久化

- **归类／要求**：自有+平台存储依赖。用户要求：修复登录保存失败和退出转圈；维护约束：落盘失败不得伪装登录成功，旧会话迟到结果不能写入新会话。 决定出处：REQ-OTHER（见文末）。
- **原版0.9.2**：原版没有Xboard登录；[lib/common/preferences_store.dart · AtomicFilePreferencesStore](https://github.com/chen08209/FlClash/blob/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7/lib/common/preferences_store.dart)及[lib/common/path.dart · AppPath](https://github.com/chen08209/FlClash/blob/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7/lib/common/path.dart)仍影响宿主偏好目录。
- **当前品牌实现**：[AuthStateNotifier._endSession](../../lib/xboard/providers/auth_state_provider.dart)协调清理；[lib/xboard/sdk/secure_storage_token_storage.dart](../../lib/xboard/sdk/secure_storage_token_storage.dart)负责持久读写/恢复；[AuthSessionSnapshot](https://github.com/wvjh3z/Xboard_sdk/blob/main/lib/src/core/auth/auth_session.dart)提供会话revision快照供调用方隔离旧结果。
- **依赖／平台／接缝**：输入为F19/F20的存储路径与SDK会话；结束会话清理F06，使F07及F26邀请/佣金/提现provider失效并重置F24恢复前台节流；F17客服重置由XboardModule认证状态监听另行触发，不是_endSession直接调用；不保证清除AppImage外部浏览器会话。S02目录/早锁影响桌面，macOS Keychain、Windows/Linux安全存储及fallback不同，Android安装签名/系统存储另验。
- **回归入口与必测分支**：写入返回失败、读回不符、旧fallback、退出未连接/已连接、换号期间旧请求/清理迟到。[test/xboard/sdk/token_storage_recovery_test.dart](../../test/xboard/sdk/token_storage_recovery_test.dart)、[test/xboard/providers/logout_test.dart](../../test/xboard/providers/logout_test.dart)、[SDK会话HTTP回归](https://github.com/wvjh3z/Xboard_sdk/blob/main/test/core/auth/auth_http_session_test.dart)。
- **限制／状态**：本轮只核对代码依赖；macOS实机存储仍属原G05及UB-GAP-01，不能因测试能读写内存替身关闭。

<a id="f06"></a>
### F06 加密订阅到Profile及内核应用

**缺口关联**：UB-GAP-05/16/17，当前进度和关闭条件见本文缺口索引所指STATUS。

**已核对升级差异**：v0.9.1默认600ms的applyProfileDebounce在v0.9.2改为按上次下发耗时限制于2–10秒；品牌订阅端口会申请此路径，但Profile ID变化还会由CoreManager下一帧调用fullSetup；它在initProvider=false时直接返回而不应用，就绪后才强制申请应用、不经该去抖。同ID刷新、初始化和强制应用等分支不同，不将调度下限差直接等同用户端至少多等1.4秒。语义唯一见[运行边界](https://github.com/wvjh3z/proxy-suite-docs/blob/main/ARCHITECTURE.md#配置应用的返回去抖与迁移边界)。

- **归类／要求**：自有下载+复用Profile执行。用户要求：保留加密订阅、代理继承及证书政策；维护约束：下载/解密/保存/选中/内核生效必须分清，写入须隔离当前会话；现有持久owner键实际为Token派生哈希，不是稳定账号ID。 决定出处：REQ-NET（见文末）。
- **原版0.9.2**：[lib/providers/actions/profiles.dart · ProfilesAction](https://github.com/chen08209/FlClash/blob/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7/lib/providers/actions/profiles.dart)处理Profile源、校验和文件；[lib/providers/actions/setup.dart · applyProfile](https://github.com/chen08209/FlClash/blob/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7/lib/providers/actions/setup.dart)应用到内核。原版没有Xboard密文和账号归属索引。
- **当前品牌实现**：[lib/xboard/services/encrypted_subscription_service.dart](../../lib/xboard/services/encrypted_subscription_service.dart)下载解密，[lib/xboard/services/xboard_subscription_service.dart](../../lib/xboard/services/xboard_subscription_service.dart)调度；[lib/xboard/services/riverpod_profile_sync_port.dart](../../lib/xboard/services/riverpod_profile_sync_port.dart)保存file型Profile、检查会话并在Core就绪后申请应用；[lib/xboard/storage/profile_mutation_queue.dart](../../lib/xboard/storage/profile_mutation_queue.dart)协调品牌写入。
- **依赖／平台／接缝**：F06a=取密文，F06b=解密校验，F06c=文件/主库/外挂索引，F06d=请求应用，F06e=内核结果；输入为F01就绪、F05归属、F14网络、F20存储，应用结果影响F08/F10。S03 Profile边界；四平台路径/锁语义不同。
- **回归入口与必测分支**：损坏密文、取消、账号切换、DB忙、校验失败、半写回滚、内核尚未ready。[test/xboard/services/encrypted_subscription_service_test.dart](../../test/xboard/services/encrypted_subscription_service_test.dart)、[test/xboard/services/xboard_subscription_service_test.dart](../../test/xboard/services/xboard_subscription_service_test.dart)、[test/xboard/services/riverpod_profile_sync_port_cleanup_test.dart](../../test/xboard/services/riverpod_profile_sync_port_cleanup_test.dart)。
- **限制／状态**：调用applyProfileDebounce不等于内核已生效；统一备份恢复与写入协调仍按U04暂缓，不把该缺口写成已解决。

<a id="f07"></a>
### F07 套餐、订单和支付

**缺口关联**：UB-GAP-06，当前进度和关闭条件见本文缺口索引所指STATUS。

- **归类／要求**：自有业务+复用二维码渲染。QrCodeView采用白底、四格留白，超长内容回退SelectableText；该组件后续变化按直接复用核对。维护约束：提交基于原会话/原服务，写请求不盲目重发；返回浏览器不等于支付成功。用户要求：兼容当前Xboard新金额字段并保留真实异常上报。 决定出处：REQ-API（见文末）。
- **原版0.9.2**：原版没有面板商业业务；邀请/佣金/分享另见F26；仅复用Flutter生命周期、通用弹窗/共享二维码组件等基础UI，不把这些复用等同订单逻辑来自上游。
- **当前品牌实现**：[lib/xboard/sdk/xboard_service_impl.dart](../../lib/xboard/sdk/xboard_service_impl.dart)对接SDK；套餐确认捕获会话和服务，订单刷新处理异步失败；[支付页order_payment_page.dart](../../lib/xboard/pages/order_payment_page.dart)实际使用共享QrCodeView；[XBoardOrderApi](https://github.com/wvjh3z/Xboard_sdk/blob/main/lib/src/panels/xboard/apis/xboard_order_api.dart)与订单adapter解析响应。
- **依赖／平台／接缝**：直接依赖F03请求恢复、F05会话、F14网络及共享UI；联查F21主题/F22异常分类。无订单专用底座接缝。两品牌业务页面共用，服务端配置/实际订单独立；所有平台的外部支付打开后都需查订单终态。
- **回归入口与必测分支**：确认期间换号/换服务、旧结果迟到、非法优惠券、支付打开失败、订单写响应不明。[test/xboard/pages/plan_confirmation_lifecycle_test.dart](../../test/xboard/pages/plan_confirmation_lifecycle_test.dart)、[test/xboard/pages/async_reload_error_test.dart](../../test/xboard/pages/async_reload_error_test.dart)、[SDK订单并发](https://github.com/wvjh3z/Xboard_sdk/blob/main/test/adapters/xboard/order_cache_concurrency_test.dart)。
- **限制／状态**：Docs/CONTRACTS登记retryableCheckout未接入且不能保证同套餐复用；不将该辅助工具当已上线保障，也不在本轮接线。

<a id="f08"></a>
### F08 连接、断开、暂停和恢复

**返回边界**：品牌adapter在需要初始化时传initialize；setRunning的true仍不能独立证明监听启动或新配置生效，取代、暂停及补排应用分支必须分别验收；SAFE_MODE当前正式入口未设置，Android启动守卫降级需单独核对。见[配置应用边界](https://github.com/wvjh3z/proxy-suite-docs/blob/main/ARCHITECTURE.md#配置应用的返回去抖与迁移边界)。

- **归类／要求**：自有展示+复用执行。用户要求：跟随上游按需连接/自动恢复；连接失败正确处理。维护约束：点击门禁和实际操作使用同一个最新目标，不依据旧帧认证。 决定出处：REQ-OTHER（见文末）。
- **原版0.9.2**：[lib/providers/actions/setup.dart · setRunning/syncSuspend](https://github.com/chen08209/FlClash/blob/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7/lib/providers/actions/setup.dart)管理请求世代、运行意图、监听器和失败回滚；[lib/providers/state/proxies.dart · isStart](https://github.com/chen08209/FlClash/blob/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7/lib/providers/state/proxies.dart)并不是系统VPN已确认的证明。
- **当前品牌实现**：[nextStartTarget/setStatus](../../lib/xboard/shell/adapters/xb_connect_adapter.dart)固定目标；[_checkConnectBlock](../../lib/xboard/shell/tabs/home/home_tab.dart)点击时读认证；[lib/xboard/shell/tabs/home/xb_connect_orb.dart](../../lib/xboard/shell/tabs/home/xb_connect_orb.dart)区分准备/连接/未连接/已连接/暂停。
- **依赖／平台／接缝**：输入为F01就绪、F05认证门禁和F06已选Profile；执行使用底座SetupAction，结果通知F04/F11，联查F09/F13配置。S01/S03是既有接入及复用定位。Android Service/VPN、桌面Core/Helper/代理路径见P矩阵。
- **回归入口与必测分支**：未重绘的登录/退出、连续点击、真实stop失败/无响应、暂停后点停止、自动恢复。[test/xboard/shell/tabs/xb_connection_target_test.dart](../../test/xboard/shell/tabs/xb_connection_target_test.dart)、[test/xboard/shell/tabs/xb_connection_failure_test.dart](../../test/xboard/shell/tabs/xb_connection_failure_test.dart)、[test/xboard/shell/tabs/xb_paused_connection_test.dart](../../test/xboard/shell/tabs/xb_paused_connection_test.dart)、[test/providers/setup_action_test.dart](../../test/providers/setup_action_test.dart)。
- **限制／状态**：启动守卫与品牌订阅同步的协调见UB-GAP-16，非首页入口见UB-GAP-14；运行意图为false不能等同原生停止完成；保留上游无响应时的安全语义，不强行回显暂停。设备结果仍按UB-GAP-01。

<a id="f09"></a>
### F09 智能／全局模式及入口一致性

- **归类／要求**：自有规则+复用模式执行。用户要求：品牌仅智能(rule)/全局(global)，隐藏直连，旧direct归一rule；保留底座三态枚举，不新增第三个品牌模式。 决定出处：REQ-MODE（见文末）。
- **原版0.9.2**：[lib/providers/actions/setup.dart · changeMode](https://github.com/chen08209/FlClash/blob/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7/lib/providers/actions/setup.dart)修改PatchClashConfig并切GLOBAL组；[lib/common/tray.dart · mode menu](https://github.com/chen08209/FlClash/blob/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7/lib/common/tray.dart)及hotkey入口原版支持三态。
- **当前品牌实现**：[lib/xboard/config/xb_mode_policy.dart](../../lib/xboard/config/xb_mode_policy.dart)用于默认/读取/写入、托盘菜单；[lib/xboard/shell/adapters/xb_mode_adapter.dart](../../lib/xboard/shell/adapters/xb_mode_adapter.dart)展示和纠偏。
- **依赖／平台／接缝**：直接写入底座PatchClashConfig/SetupAction；旧值由F20配置恢复进入，变化影响F10分组、F11检测及F13配置应用，联查F08展示。S04是已登记模式接缝。桌面托盘/快捷键与四平台配置恢复/首页都需一致；Android磁贴不是模式切换入口。
- **回归入口与必测分支**：旧direct、托盘/快捷键循环、快速切换与GLOBAL联动、非品牌保持三态。[test/xboard/config/xb_mode_policy_test.dart](../../test/xboard/config/xb_mode_policy_test.dart)、[test/xboard/config/xb_mode_hotkeys_test.dart](../../test/xboard/config/xb_mode_hotkeys_test.dart)、[test/xboard/shell/adapters/xb_mode_adapter_test.dart](../../test/xboard/shell/adapters/xb_mode_adapter_test.dart)。
- **限制／状态**：模式provider先变、Core后应用；F11／UB-GAP-02记录严格配置完成关联未实现，不把模式高亮当生效确认。

<a id="f10"></a>
### F10 节点列表与当前选择

**补充边界**：撤回“选中超时节点会被过滤”的旧推断。computeHideTimeout保留当前选中项、子分组及不可测类型，过滤为空时恢复原列表；通常只隐藏非选中超时节点。首页无法取得有效真实选中项而回退首个真实节点时，该回退项可能不在过滤结果中，仍需真实provider验证。v0.8.93没有该字段；来源应限定为后续已含该字段的配置/完整恢复等，不能归因于0.8.93普通迁移。见UB-GAP-04。

- **归类／要求**：自有页面+复用分组/选择。用户要求：全局节点按原版处理，不能因GLOBAL.hidden导致空列表。维护约束：乐观选择失败回滚，首页/节点页对当前分组与叶子节点一致。 决定出处：REQ-OTHER（原版全局分组行为复用；具体决定日期待确认）。
- **原版0.9.2**：[lib/providers/state/proxies.dart · currentGroupsState/proxiesTabState](https://github.com/chen08209/FlClash/blob/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7/lib/providers/state/proxies.dart)对rule/global/direct采用不同分组过滤；[lib/providers/actions/proxies.dart · changeProxyDebounce](https://github.com/chen08209/FlClash/blob/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7/lib/providers/actions/proxies.dart)处理选择及回滚。
- **当前品牌实现**：[nodesView/currentSelection](../../lib/xboard/shell/adapters/xb_nodes_adapter.dart)消费proxiesTabState；全局保留GLOBAL，首页从groups+selectedMap下钻叶子，非builtin才作为候选。
- **依赖／平台／接缝**：输入为F06生成的Profile/底座groups、F09模式和选择状态；结果被首页及F12测速使用，选择变化也触发F11。S03的FA-proxiestabstate等仅为复用锚点，不是新增接缝。四平台同provider链，桌面/手机交互另验。
- **回归入口与必测分支**：rule→global→rule、hidden组、未手选GLOBAL、选择失败、旧分组残留。[test/xboard/shell/tabs/nodes_mode_transition_test.dart](../../test/xboard/shell/tabs/nodes_mode_transition_test.dart)、[test/xboard/shell/adapters/xb_nodes_selection_test.dart](../../test/xboard/shell/adapters/xb_nodes_selection_test.dart)。
- **限制／状态**：U03：共享filterGroupsState仍读取hideTimeoutProxies；明确列为已知间接影响，不把当前实现当用户希望保留的行为。

<a id="f11"></a>
### F11 出口IP探测、调度与显示

- **归类／要求**：自有探测+复用网络/路由通知。用户要求：旧品牌七源机制和网址，跟随全局证书政策；手动刷新可见检测状态。维护约束：迟到结果不覆盖新轮，保留旧值时必须标注不是新成功。 决定出处：REQ-IP（见文末）。
- **原版0.9.2**：[lib/providers/outbound_ip.dart · OutboundIpProbe](https://github.com/chen08209/FlClash/blob/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7/lib/providers/outbound_ip.dart)通过Core查询，[lib/providers/routed_probe.dart · RoutedProbe](https://github.com/chen08209/FlClash/blob/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7/lib/providers/routed_probe.dart)以路由stamp/hits验证缓存；不是品牌Dio七源机制。
- **当前品牌实现**：[lib/xboard/services/exit_ip_probe.dart](../../lib/xboard/services/exit_ip_probe.dart)并发七源首个有效结果胜出；[lib/xboard/providers/exit_ip_provider.dart](../../lib/xboard/providers/exit_ip_provider.dart)集中触发、取消及generation隔离；[lib/xboard/shell/tabs/home/xb_ip_card.dart](../../lib/xboard/shell/tabs/home/xb_ip_card.dart)区别首测/手动、上次结果复核及复核失败；移除首页/连接按钮重复startCheck。
- **依赖／平台／接缝**：F11a=七源HTTP，UA直接依赖[lib/common/constant.dart · browserUa](https://github.com/chen08209/FlClash/blob/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7/lib/common/constant.dart)，联查F28；F11b=全局路由，F11c=事件调度，F11d=状态展示。直接监听F08运行/暂停、F09模式、F10选择、mixedPort和代理认证，以及底座RouteTracker/appVisible，HTTP使用F14；与F04品牌竞速观察器是并列消费者，不调用其race。S01 HttpOverrides是既有依赖，IP本身没有新增底座接缝。
- **回归入口与必测分支**：首测快于RouteTracker首次同步、迟到版本通知、真实世代变化、同快照、取消/失败/恢复。[test/xboard/services/exit_ip_probe_test.dart](../../test/xboard/services/exit_ip_probe_test.dart)、[test/xboard/shell/tabs/exit_ip_lifecycle_test.dart](../../test/xboard/shell/tabs/exit_ip_lifecycle_test.dart)、[test/xboard/shell/tabs/xb_ip_card_test.dart](../../test/xboard/shell/tabs/xb_ip_card_test.dart)。
- **限制／状态**：UB-GAP-02：没有配置操作编号关联；底座600ms与IP300ms调度独立，第一轮可能先于配置生效，后续复核仍必要。#144/#146含显示修复，真机复验未关闭；不把副作用固化为需求。

<a id="f12"></a>
### F12 节点测速与首页延迟

**源码补充**：首页测速在有效世代完成时把多轮最小有效值（无有效值为-1）写回共享延迟表，再更新首页状态，因此也可能影响节点页延迟；异常分支与世代失效不等同正常完成写回。

- **归类／要求**：自有调度+复用Core探测。维护约束：不同组/节点及批次结果不串用；无结果、检测中、超时分开显示。保留品牌并发与首页当前叶子测量，不自动照搬原版整组策略。
- **原版0.9.2**：[lib/providers/actions/proxies.dart · ProxiesAction](https://github.com/chen08209/FlClash/blob/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7/lib/providers/actions/proxies.dart)和[lib/core/controller.dart · getDelay](https://github.com/chen08209/FlClash/blob/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7/lib/core/controller.dart)提供代理测试入口；上游UI状态不是品牌延迟缓存。
- **当前品牌实现**：[measureCurrentNodeBest](../../lib/xboard/shell/adapters/xb_nodes_adapter.dart)与[providers/home_latency_provider.dart](../../lib/xboard/providers/home_latency_provider.dart)处理首页独立测量状态/generation，监听运行、暂停、认证、Profile和模式重置；同名home目录文件仅为兼容export。底座执行请求，首页延迟不直接复用节点页历史表。
- **依赖／平台／接缝**：输入为F10组/叶子及底座getDelay、测试URL，F06/F09改变测试目标；不依赖IP探测结果。S03复用锚点。Android/桌面访问同Core接口，跨网络实际延迟另测；不能用UI主题测试当网络测试。
- **回归入口与必测分支**：切组/节点后的迟到值、超时重试、退出页面、测量期间配置变化。[test/xboard/shell/adapters/xb_nodes_latency_lifecycle_test.dart](../../test/xboard/shell/adapters/xb_nodes_latency_lifecycle_test.dart)、[test/xboard/shell/tabs/measuring_nodes_test.dart](../../test/xboard/shell/tabs/measuring_nodes_test.dart)。
- **限制／状态**：网络抖动不是代码回归自动通过的证明；显示单位/空值以Docs/CONTRACTS为准。

<a id="f13"></a>
### F13 系统代理、TUN、DNS、IPv6与Geo更新

**源码补充**：首页系统代理/TUN开关位于双栏布局，条件是内容宽度达到840逻辑像素，不以OS判断；Android宽屏也可能显示。属于既有布局行为，不认定0.9.2新增回归；Android上的实际效果与是否保留待验证/决定。Geo事件归属见UB-GAP-10。

**新装/升级差异**：仅当反序列化的旧配置缺general-override-keys时补回unifiedDelay、tcpConcurrent、ipv6、geodataLoader；新默认集合为空，品牌首次设置补IPv6。已有该键的配置不会无条件补回四项。实际下发还受Profile YAML与内核默认影响；生产模板内容待核实。详见[配置应用边界](https://github.com/wvjh3z/proxy-suite-docs/blob/main/ARCHITECTURE.md#配置应用的返回去抖与迁移边界)。


- **归类／要求**：复用执行+自有首次默认/Geo调度。用户要求：使用新版原有配置与执行入口，保留品牌首次IPv6默认策略（不表示品牌设置页布局等同原版）；维护约束：用户后续选择不被启动覆盖，开关显示不能替代系统状态。 决定出处：REQ-SETTINGS / REQ-IPV6（见文末）。
- **原版0.9.2**：[lib/models/clash_config.dart · PatchClashConfig/toUpdateParams](https://github.com/chen08209/FlClash/blob/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7/lib/models/clash_config.dart)的ipv6默认false，覆盖键决定传给内核哪些值；[lib/providers/actions/setup.dart · updateConfig](https://github.com/chen08209/FlClash/blob/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7/lib/providers/actions/setup.dart)与系统/Helper应用设置。
- **当前品牌实现**：[_wireDefaultIpv6](../../lib/xboard/xboard_module.dart)首次设置true并加入GeneralOverrideKey.ipv6，后续尊重保存值；桌面首页通过[xb_takeover_adapter.dart](../../lib/xboard/shell/adapters/xb_takeover_adapter.dart)写networkSettingProvider.systemProxy和patchClashConfigProvider.tun.enable；系统代理、TUN、DNS执行沿用底座，配置值不是原生生效证明。F13b另由[品牌Geo服务](../../lib/xboard/services/xb_geo_update_service.dart)在有效VPN连上后延迟检查七天成功间隔（连接后45秒、会话尝试节流30分钟），调用Core.updateGeoData并等待匹配完成事件才记录成功；这是当前自有调度，不等于原版geo-auto-update定时器。原版[lib/models/core.dart](https://github.com/chen08209/FlClash/blob/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7/lib/models/core.dart)默认geoAutoUpdate=false、geoUpdateInterval=24小时；F23资源页可以打开。Geo自动更新由Core读取配置执行；[lib/providers/actions/resources.dart](https://github.com/chen08209/FlClash/blob/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7/lib/providers/actions/resources.dart)的autoUpdate只处理图标、脚本和规则提供者，不额外自动下载Geo。需联查品牌七天调度、Core自动Geo和手动Geo三条来源。
- **依赖／平台／接缝**：F13a=设置/系统执行，F13b=品牌Geo调度；输入为F01初始化、F08有效VPN事件和F19身份，联查F14网络/证书。S01/S05是既有身份/初始化边界，Geo自有层没有专用新接缝。Android系统VPN授权与桌面代理/Helper权限不同，各OS系统状态另验。
- **回归入口与必测分支**：新安装/旧配置/覆盖键缺失、手动关闭后重开、权限拒绝、设置失败、断开清理。[test/xboard/config/xb_v092_config_migration_test.dart](../../test/xboard/config/xb_v092_config_migration_test.dart)、[test/providers/setup_action_test.dart](../../test/providers/setup_action_test.dart)、[Geo完成事件](../../test/xboard/services/geo_update_completion_test.dart)；后者验证应答/完成事件分离、3分钟超时和Core中途停止；还应覆盖45秒延迟取消、30分钟节流、七天边界和F23手动更新并发，不能称整个调度已验；系统状态按P矩阵实测。
- **限制／状态**：这里的“默认”是品牌首次配置和原版字段默认分别记录，不声称所有实际订阅或所有设备IPv6均已生效。

<a id="f14"></a>
### F14 TLS及HTTP代理政策

- **归类／要求**：自有业务政策+复用宿主。用户要求：品牌首次默认关闭校验TLS；Xboard业务通道忽略证书并继承代理；IP按全局；第三方组件维持现状。 决定出处：REQ-NET（见文末）。
- **原版0.9.2**：[lib/models/config.dart · AppSettingProps.checkCertificate](https://github.com/chen08209/FlClash/blob/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7/lib/models/config.dart)默认true；[lib/common/http.dart · FlClashHttpOverrides](https://github.com/chen08209/FlClash/blob/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7/lib/common/http.dart)决定Dart宿主网络；内核节点协议不是同一通道。
- **当前品牌实现**：[xbMigrateWithInitialTlsDefault](../../lib/xboard/config/xb_tls_defaults.dart)以持久标记/读回完成首次false，已有用户选择不改；[XboardReleaseHttp](../../lib/xboard/services/xboard_release_dio.dart)集中业务独立放行并关闭持久连接；IP仅继承宿主。
- **依赖／平台／接缝**：F14a=首次全局默认，F14b=Xboard业务，F14c=IP，F14d=第三方/节点。初始化接入F01；下游为F02/F03/F06/F11/F16/F18等HTTP消费者。S01既有bootstrap/HttpOverrides接缝；各平台原生浏览器/客服不保证跟随Dart。
- **回归入口与必测分支**：首次写失败重入、已有配置/损坏配置、连接/断开后同HTTPS不复用旧代理隧道、探针TLS。[test/xboard/config/xb_tls_defaults_test.dart](../../test/xboard/config/xb_tls_defaults_test.dart)、[test/xboard/services/xb_update_https_routing_test.dart](../../test/xboard/services/xb_update_https_routing_test.dart)、[test/xboard/services/endpoint_probe_tls_test.dart](../../test/xboard/services/endpoint_probe_tls_test.dart)。
- **限制／状态**：证书放行是用户接受的产品政策，不是本轮建议修改的缺陷；范围和风险唯一见SECURITY，不能泛化为所有协议全局放行。

<a id="f15"></a>
### F15 更新检查与24小时时窗

- **归类／要求**：自有调度/面板版本协议。用户要求：保留应用内检查更新，其他平台恢复前台也按24小时规则；维护约束：失败/取消不冒充成功检查，不在API未ready时误报。 决定出处：REQ-UPDATE（见文末）。
- **原版0.9.2**：[lib/common/request.dart · checkForUpdate](https://github.com/chen08209/FlClash/blob/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7/lib/common/request.dart)查原版release；[lib/providers/actions/common.dart · autoCheckUpdate/checkUpdateResultHandle](https://github.com/chen08209/FlClash/blob/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7/lib/providers/actions/common.dart)处理原版版本提示。
- **当前品牌实现**：[XbUpdateService](../../lib/xboard/services/xb_update_service.dart)等待有效API、区分冷启动/手动/成功后24小时，XboardModule通过[xboard_lifecycle_observer.dart](../../lib/xboard/services/xboard_lifecycle_observer.dart)接恢复前台；冷启动检查来自XboardModule的bootstrap异步阶段；F24账号刷新是另一回调/时窗；品牌bootstrap门禁阻止上游自动更新混入。
- **依赖／平台／接缝**：输入为F03有效API、F14网络和版本响应，由F01启动、生命周期与F04有效VPN回调触发；更新信息交给F16。S01的SEAM-bootstrap-update为既有门禁。四平台生命周期不同，手动检查与自动时窗不得错误共用成功时间戳。
- **回归入口与必测分支**：早期resumed、有效API迟到、失败重试、24小时边界、手动检查、跨品牌版本来源。[test/xboard/services/xb_update_service_test.dart](../../test/xboard/services/xb_update_service_test.dart)。
- **限制／状态**：API重新竞速不等于执行版本检查；源码/测试存在不能证明设备每次恢复都会收到相同生命周期事件。

<a id="f16"></a>
### F16 下载、安装交接与退出

**点击选源**：更新与浏览器下载入口新建独立地区探测（最多3秒，不改变首页IP）；CN/海外优先，地区组内随机，URL去重并冻结本轮顺序。检测失败回退接口region，仍未知保留后台顺序；不做下载地址测活，既有5秒连接/5分钟接收超时未改。浏览器只能确认打开请求。具体实现与回归见xb_update_region.dart、xb_update_sources.dart和xb_update_region_test/xb_update_selection_test，实际验收归STATUS。

**补充边界**：非AppImage的Linux路径在下载完成后才检查APPIMAGE，缺失时返回installFailed，界面提示手动安装；未实现下载前格式阻断，不能由源码注释推断自动浏览器回退。是否提前提示待产品决定。

- **归类／要求**：自有更新能力+复用退出/安装器。用户要求：保留应用内下载/安装和AppImage自替换；取消安装包SHA256校验；Windows常规关闭遵循原版，不恢复额外服务路径/最终进程检查。 决定出处：REQ-UPDATE（见文末）。
- **原版0.9.2**：[lib/providers/actions/common.dart · checkUpdateResultHandle](https://github.com/chen08209/FlClash/blob/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7/lib/providers/actions/common.dart)可打开原版发布页；[lib/providers/actions/system.dart · handleExit](https://github.com/chen08209/FlClash/blob/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7/lib/providers/actions/system.dart)执行正常退出；[windows/packaging/exe/inno_setup.iss · PrepareToInstall/InitializeUninstall](https://github.com/chen08209/FlClash/blob/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7/windows/packaging/exe/inno_setup.iss)负责安装事件。
- **当前品牌实现**：[lib/xboard/services/xb_apk_downloader.dart](../../lib/xboard/services/xb_apk_downloader.dart)与[lib/xboard/widgets/xb_update_dialog.dart](../../lib/xboard/widgets/xb_update_dialog.dart)分平台交接；[lib/xboard/services/xb_appimage_install.dart](../../lib/xboard/services/xb_appimage_install.dart)/[lib/xboard/services/xb_appimage_restart.dart](../../lib/xboard/services/xb_appimage_restart.dart)恢复旧包；Win安装器加入品牌身份/VC门禁/安全可选数据删除；PrepareToInstall先执行VC门禁，失败立即返回，之后才按原版顺序卸载Helper和停止进程。
- **依赖／平台／接缝**：输入为F15更新信息、F14下载网络、F19身份/临时目录；退出调用底座SystemAction，Windows可选数据删除联查F20，成品符号联查F22。S06/S07；严格按P01—P06区分，不能将Win/AppImage退出策略套到Android/macOS。
- **回归入口与必测分支**：取消下载/UAC/安装向导、启动失败/恢复失败、保留备份、旧实例退出、URL排序。[test/xboard/services/xb_apk_downloader_routing_test.dart](../../test/xboard/services/xb_apk_downloader_routing_test.dart)、[tool/test/appimage_restart_test.py](../../tool/test/appimage_restart_test.py)、[tool/test/windows_upstream_installation_test.py](../../tool/test/windows_upstream_installation_test.py)。
- **限制／状态**：启动安装器不等于覆盖完成；不校验SHA的决定不等于忽略HTTP失败、无效文件或平台安装失败。严格全局退出握手按U05不实施。

<a id="f17"></a>
### F17 Crisp客服

- **归类／要求**：自有接入+第三方SDK。用户要求：两个品牌保留客服，桌面升级desktop_webview_window 0.4.0，AppImage走浏览器；Android保留原生SDK并修复资源崩溃。 决定出处：REQ-CRISP（见文末）。
- **原版0.9.2**：原版没有Crisp业务；复用[plugins/window/lib/window.dart · window plugin](https://github.com/chen08209/FlClash/blob/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7/plugins/window/lib/window.dart)的窗口/平台环境及正常退出机制。不能称Crisp行为属于原版责任。
- **当前品牌实现**：[mine_tab.dart · _openSupport](../../lib/xboard/shell/tabs/mine/mine_tab.dart)先按usesExternalBrowser分流；AppImage走[crisp_appimage_browser.dart](../../lib/xboard/services/crisp_appimage_browser.dart)，[crispVisitorUri](../../lib/xboard/services/crisp_navigation.dart)生成的visitor URL仅带website_id，不注入账户资料。嵌入式分支才由[crisp_support_service.dart](../../lib/xboard/services/crisp_support_service.dart)隔离会话/打开任务，并使用[crisp_chat_driver.dart](../../lib/xboard/services/crisp_chat_driver.dart)的移动原生或桌面驱动。兼容副本与Android SDK资源在正式链检查。
- **依赖／平台／接缝**：输入为F05当前会话、F19品牌配置及第三方插件；生命周期/崩溃联查F22。S08窗口聚焦/Win退出，S06 Android兼容与资源检查。Android原生，Win/Mac/DEB/RPM内嵌，AppImage浏览器；按实际格式检测与平台驱动选择，不仅看文件名。
- **回归入口与必测分支**：打开中换号/关闭、旧回调、退出释放、AppRun污染环境、APK关键资源/引用链。[test/xboard/services/crisp_session_lifecycle_test.dart](../../test/xboard/services/crisp_session_lifecycle_test.dart)、[tool/test/crisp_appimage_browser_test.dart](../../tool/test/crisp_appimage_browser_test.dart)、[tool/check_android_release_contract.py](../../tool/check_android_release_contract.py)、[tool/test/windows_webview_shutdown_test.py](../../tool/test/windows_webview_shutdown_test.py)。
- **限制／状态**：真实客服打开及崩溃是否捕获另验，符号成功不证明第三方进程已接入Sentry；外部浏览器自行保管Cookie/会话，客户端登出/reset不能保证清除它，不把嵌入式账号隔离结论外推到AppImage。

<a id="f18"></a>
### F18 教程与链接导航

- **归类／要求**：自有阅读器+平台WebView。用户要求：教程保留阅读器及回退；不能跟随AppImage客服一律改浏览器。维护约束：内部教程与普通外链分开，旧页面回调无效。 决定出处：REQ-SETTINGS（见文末）。
- **原版0.9.2**：原版没有Xboard知识库阅读器；宿主退出、窗口和平台依赖来自底座，共享网络政策见F14。
- **当前品牌实现**：[lib/xboard/pages/tutorial_detail_page.dart](../../lib/xboard/pages/tutorial_detail_page.dart)加载正文；[lib/xboard/widgets/tutorial_webview.dart](../../lib/xboard/widgets/tutorial_webview.dart)承接平台阅读，[lib/xboard/widgets/tutorial_html_fallback.dart](../../lib/xboard/widgets/tutorial_html_fallback.dart)提供回退；TutorialWebView内部_generation和_open处理世代、内部教程及外链，回退阅读器复用_open；TutorialDetailPage另有会话检查。
- **依赖／平台／接缝**：输入为F03知识库API、F05当前会话、F14正文网络政策及品牌资源基址；S08为Windows WebView兼容/退出。Linux回退正文/外链与AppImage客服是独立功能，macOS/Android/Windows各自WebView权限另验。
- **回归入口与必测分支**：跳转按钮、相对URL、内部教程、普通外链、失败回退、换页后回调。[test/xboard/widgets/tutorial_linux_navigation_test.dart](../../test/xboard/widgets/tutorial_linux_navigation_test.dart)、[test/xboard/pages/tutorial_pages_test.dart](../../test/xboard/pages/tutorial_pages_test.dart)。
- **限制／状态**：阅读器源码可用不等于任意后台HTML都兼容；Linux回退不证明Mac/Windows原生WebView行为。

<a id="f19"></a>
### F19 品牌身份、目录、图标及并存

**补充边界**：资源修复与设备状态见UB-GAP-15；深链及FilesProvider入口分别见UB-GAP-17/18。

**冻结点后的变化**：6055a4be修改品牌B Android三份adaptive资源及回归；VDS build36同号包和设备待验见[批次记录](https://github.com/wvjh3z/proxy-suite-docs/blob/main/evidence/brand-b-build36-vds-icon-replacement/README.md)。几何测试只覆盖B，不能用作A或所有最终包的图标证明。

**资源缺口入口**：Android宽布局侧栏也读取assets/images/icon.png，不能按桌面组件排除Android；8081旧包资源相等证据、新发布A/B待验及TV资源边界统一见[STATUS](https://github.com/wvjh3z/proxy-suite-docs/blob/main/STATUS.md#基线局部缺口与发布待办)的UB-GAP-12/13。


- **归类／要求**：自有隔离+复用平台集成。用户要求：原版、A、B可并存，名字/目录/服务不冲突；中文不可用处B使用daishu；升级保持原签名和可识别包身份。 决定出处：REQ-IDENTITY（见文末）。
- **原版0.9.2**：[lib/common/constant.dart · packageName](https://github.com/chen08209/FlClash/blob/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7/lib/common/constant.dart)、[lib/common/path.dart · AppPath](https://github.com/chen08209/FlClash/blob/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7/lib/common/path.dart)、原生Runner和Helper使用原版身份。显示名、applicationId、服务名不是同一个字段。
- **当前品牌实现**：[tool/identity/brands.json](../../tool/identity/brands.json)维护公开内部身份，[tool/brand_identity.dart](../../tool/brand_identity.dart)构建注入，[lib/xboard/storage/brand_paths.dart](../../lib/xboard/storage/brand_paths.dart)选择目录；品牌flavor提供显示/资源及受限配置，不在本文复制值。
- **依赖／平台／接缝**：身份源供F01/F05/F13/F16/F17/F20/F22使用；S02/S05/S06。A/B各自包名、目录、端口、服务、scheme、签名、fallback、Sentry项目须查实际生成物；共享代码不替代B成品验收。
- **回归入口与必测分支**：A/B/原版三者共存、中文/Unicode/单引号、重复注入、不同启动目录、原生通道与最近任务名。[tool/test/brand_identity_cli_test.py](../../tool/test/brand_identity_cli_test.py)、[tool/test/brand_data_runtime_test.py](../../tool/test/brand_data_runtime_test.py)、[tool/test/android_brand_identity_test.dart](../../tool/test/android_brand_identity_test.dart)、[tool/test/windows_title_encoding_test.py](../../tool/test/windows_title_encoding_test.py)。
- **限制／状态**：UB-GAP-01包括旧包升级/真实注册表/桌面快捷方式；身份表为内部标识真源，不能以营销显示名推断包ID。

<a id="f20"></a>
### F20 数据库、旧数据迁移及恢复

**缺口关联**：UB-GAP-05/18，当前进度和关闭条件见本文缺口索引所指STATUS。

- **归类／要求**：复用主库+自有归属/有限重试。用户要求：主库跟随新版；修复数据库锁和迁移中断恢复。维护约束：不能整体搬运原版共享目录或借重试重复副作用。统一备份协调暂缓。 决定出处：REQ-IDENTITY（见文末）。
- **原版0.9.2**：[lib/database/database.dart · Database](https://github.com/chen08209/FlClash/blob/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7/lib/database/database.dart)主库schema21；[lib/common/migration.dart · Migration.run](https://github.com/chen08209/FlClash/blob/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7/lib/common/migration.dart)迁移配置；[lib/providers/actions/backup.dart · BackupAction.restore](https://github.com/chen08209/FlClash/blob/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7/lib/providers/actions/backup.dart)是底座恢复入口。
- **当前品牌实现**：[lib/xboard/storage/legacy_brand_migration.dart](../../lib/xboard/storage/legacy_brand_migration.dart)只选可确认品牌归属凭据，新数据优先；[lib/xboard/storage/profile_database_access.dart](../../lib/xboard/storage/profile_database_access.dart)有限busy等待/安全写重试；[lib/xboard/data/xboard_database.dart](../../lib/xboard/data/xboard_database.dart)外挂schema2以事务/可重入触发器守住归属。
- **依赖／平台／接缝**：输入为F19隔离目录及上游schema/配置；F01启动调用迁移，F05/F06读写归属记录，底座BackupAction另有恢复路径。S02早锁及SEAM-profile-db-open；Android与桌面锁语义不同，外挂库与主库迁移不是同一事务。
- **回归入口与必测分支**：中断重开、旧重复数据、事务失败、只读/占用、换号旧清理、目录隔离。[test/xboard/data/xboard_database_migration_test.dart](../../test/xboard/data/xboard_database_migration_test.dart)、[test/xboard/storage/profile_database_access_test.dart](../../test/xboard/storage/profile_database_access_test.dart)、[test/xboard/storage/brand_paths_test.dart](../../test/xboard/storage/brand_paths_test.dart)。
- **限制／状态**：U04明确未统一BackupAction与品牌订阅写入协调；已有profile_mutation_queue不能证明所有恢复入口参与。

<a id="f21"></a>
### F21 主题、字体、设置与界面外壳

**资源核对**：共用侧栏与Android资源范围见[F19](#f19)，不另维护一份缺口说明。


- **归类／要求**：自有外壳+部分复用主题；字体选择衔接有待处理缺口。用户要求：系统亮暗自适应，字体跟随原版方案；设置使用新版入口。维护约束：尊重已有用户偏好，文本保留字体继承，不能把默认改动强推给旧用户。 决定出处：REQ-THEME / REQ-FONT（见文末）。
- **原版0.9.2**：[lib/models/config.dart · ThemeProps](https://github.com/chen08209/FlClash/blob/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7/lib/models/config.dart)默认ThemeMode.system；[lib/common/system_fonts.dart · system fonts](https://github.com/chen08209/FlClash/blob/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7/lib/common/system_fonts.dart)、[lib/providers/actions/theme.dart · ThemeAction](https://github.com/chen08209/FlClash/blob/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7/lib/providers/actions/theme.dart)负责亮暗/视图等状态；字体选择与回退由lib/manager/theme_manager.dart的watchAppTheme及lib/ui/font.dart处理，ThemeAction不承担字体应用。
- **当前品牌实现**：[lib/xboard/widgets/xb_theme.dart](../../lib/xboard/widgets/xb_theme.dart)及品牌Home/Nodes/Mine展示；[lib/xboard/shell/tabs/mine/xb_settings_page.dart](../../lib/xboard/shell/tabs/mine/xb_settings_page.dart)连接设置；[xb_layout_adapter.dart](../../lib/xboard/shell/adapters/xb_layout_adapter.dart)转发isMobileViewProvider（按宽度，不按OS），[xb_emoji_text.dart](../../lib/xboard/widgets/xb_emoji_text.dart)保留文字字体继承并单独处理emoji。窗口尺寸/标题栏配色、中文语言策略仍有品牌差异；底座原生子页见F23。
- **依赖／平台／接缝**：亮暗/缩放复用上游状态，但XbBrandTheme仅传亮暗和品牌色，新建ThemeData未继承用户fontFamily及上游汉字fallback；经ThemeManager/ThemeAction更新viewSize等上游状态间接依赖；品牌样式为自有，未发现lib/xboard直接调用ThemeAction，供Home/Nodes/Mine和各业务页面消费；联查F08/F09展示、F19标题/资源。S09外壳/标题/窗口尺寸；Android缩放、Win字体替换、Mac/Linux fallback分别验。system主题不等于强制亮色。
- **回归入口与必测分支**：亮暗切换、旧偏好重开、中文字体、字体缺字、桌面最小尺寸/缩放。[test/xboard/widgets/xb_font_inheritance_test.dart](../../test/xboard/widgets/xb_font_inheritance_test.dart)、[test/xboard/shell/tabs/dark_mode_test.dart](../../test/xboard/shell/tabs/dark_mode_test.dart)、[test/xboard/shell/tabs/xb_settings_page_test.dart](../../test/xboard/shell/tabs/xb_settings_page_test.dart)。
- **限制／状态**：UB-GAP-19登记字体衔接缺口；现有xb_font_inheritance_test对照Material默认ThemeData，不能证明用户选字体被继承。具体验证范围见[字体选择验收计划](https://github.com/wvjh3z/proxy-suite-docs/blob/main/runbooks/DEVICE_ACCEPTANCE.md#字体选择与品牌主题验收计划)。像素golden和真实系统字体为不同证据，不能把截图变化直接归因为系统字体；语言/品牌布局是有意差异。

<a id="f22"></a>
### F22 异常分类、Sentry与符号链

- **归类／要求**：自有上报/构建治理+复用错误入口。用户要求：邮箱密码/优惠券等预期业务拒绝不生成独立Issue，真实异常继续上报；匹配符号自动上传，尊重上报选择。 决定出处：REQ-OTHER（见文末）。
- **原版0.9.2**：[lib/main.dart · FlutterError.onError/runZonedGuarded](https://github.com/chen08209/FlClash/blob/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7/lib/main.dart)记录错误；原版构建原生资产的Go/Rust/Helper流程不是本项目Sentry验收链。
- **当前品牌实现**：[lib/xboard/services/sentry_bootstrap.dart](../../lib/xboard/services/sentry_bootstrap.dart)安装主进程监控、保留宿主handler，SDK分类业务错误；[tool/postbuild_sentry_symbols.py](../../tool/postbuild_sentry_symbols.py)及[tool/release_pipeline.py](../../tool/release_pipeline.py)关联本轮成品、符号和服务端处理。
- **依赖／平台／接缝**：F01安装监控、F19提供发布身份，消费SDK业务错误分类；联查F03/F05/F16/F17异常与退出。S01/S06/S08为既有原生hook/退出边界。A/B项目与release独立，Android双ABI/Win PDB/Linux debug/Mac dSYM按P矩阵检查。
- **回归入口与必测分支**：预期业务错误/真实异常、偏好开关、缓存失效、上传失败/取消及恢复、符号匹配。[test/xboard/services/sentry_bootstrap_test.dart](../../test/xboard/services/sentry_bootstrap_test.dart)、[SDK预期拒绝日志](https://github.com/wvjh3z/Xboard_sdk/blob/main/test/core/http/business_rejection_logging_test.dart)、[tool/test/sentry_macos_receipt_validation_test.py](../../tool/test/sentry_macos_receipt_validation_test.py)。
- **限制／状态**：有符号附件/上传命令成功不等于逐ID完成或真实崩溃可解析；独立原生进程覆盖和预编译库限制继续列原G19及UB-GAP-01，不改Sentry设置。

<a id="f23"></a>
### F23 底座原生子页及设置恢复

**源码补充**：原版ToolsView还含语言、桌面快捷键、自定义资源、免责声明、开发者和关于；原版导航另有DNS查询/日志。品牌当前未找到HotKeyView、CustomResourcesView、DnsQueriesView、LogsView、DeveloperView生产入口，语言/关于/免责声明按既有决定隐藏。新装macOS/Linux仍可能注册默认全局快捷键，注册不依赖设置页可达；是否开放管理入口或改变默认值另行决定，见UB-GAP-14。

**缺口关联**：UB-GAP-11/17，当前进度和关闭条件见本文缺口索引所指STATUS。

- **归类／要求**：复用页面/执行+自有导航。既有决定：保留新版设置能力，品牌只组织入口；来源REQ-SETTINGS。ToolsView方法存在不等于品牌页面实际进入整张工具页。
- **原版0.9.2**：原版`lib/views/tools.dart`导航到theme、backup_and_restore、access、config/general、config/advanced、connection/requests、connection/connections、resources和about；对应动作可能改写整份Config或更新Core资源。
- **当前品牌实现**：[xb_settings_page.dart](../../lib/xboard/shell/tabs/mine/xb_settings_page.dart)经[xb_native_page_adapter.dart](../../lib/xboard/shell/adapters/xb_native_page_adapter.dart)提供上述适配方法，但当前语言和“其他”组隐藏，原版About/免责声明不是当前可见入口；原生一级push页面当前Android可见8个、桌面7个，访问控制仅Android；还须沿通用设置的按需连接/UA/映射和进阶配置的网络/DNS/脚本/附加规则继续核对，一级数量不是全部可达页面数。完整条件及动作见[配置与可达性清单](https://github.com/wvjh3z/proxy-suite-docs/blob/main/evidence/upgrade-v0.9.2/DEPENDENCY_CONFIG_REACHABILITY.md#f23实际可达性)。桌面设置Tab也嵌入XbSettingsPage，不再嵌入ToolsView；openNativeTools/toolsView仅保留适配方法，本轮lib/xboard搜索未找到生产调用。
- **依赖／平台／接缝**：直接依赖底座视图/动作，输入受F19路径与配置影响。BackupAction完整恢复（非onlyProfiles）调用writeConfig，会重引入U03 hideTimeoutProxies；ResourcesView手动Geo更新与F13b共用Core/完成事件，需并发核对。S09/FA-toolsview是参照，不应误标为已使用Widget。
- **回归入口与必测分支**：[导航测试](../../test/xboard/shell/adapters/xb_native_page_adapter_test.dart)只证明openNativeTools可push，不能证明所有生产子页与副作用；[设置页测试](../../test/xboard/shell/tabs/xb_settings_page_test.dart)、上游备份/资源测试及真实Config恢复按入口补验。
- **限制／状态**：备份统一协调仍按U04暂缓；手动Geo、Core自动Geo与品牌自动Geo的同类型完成事件是否会互相满足，列UB-GAP-10待核对，不假定独立请求ID隔离。

<a id="f24"></a>
### F24 账号资料刷新与订阅触发

- **归类／要求**：自有调度+复用生命周期。既有24小时刷新与登录门控来源REQ-REFRESH；维护约束：账号资料API与加密订阅下载是两个动作，不能以其中成功推断另一完成。
- **原版0.9.2**：原版没有Xboard账号资料；Flutter生命周期只提供事件，不能自动推导品牌刷新窗口。
- **当前品牌实现**：[xboard_lifecycle_observer.dart](../../lib/xboard/services/xboard_lifecycle_observer.dart)在resumed对移动分支及Windows调用onForegroundRefresh；24小时前台资料/订阅刷新分支在当前发行目标中仅接Android/Windows；所有平台resumed还调用onRecoverPending，已登录时尝试recoverPending，并执行各自更新检查/竞速，不把这个刷新范围误写成发行平台范围。XboardModule接到[SubscriptionTriggers.onResume](../../lib/xboard/services/subscription_triggers.dart)，通过ready+authenticated门控后启动Stopwatch，再sync订阅并invalidate [userProfileProvider](../../lib/xboard/providers/user_profile_provider.dart)。
- **依赖／平台／接缝**：输入F01/F05及生命周期；调用F06和账号API（F03/F14），与F15独立。24小时按本进程触发计时，退出会重置；当前在动作开始前耗用窗口，不是成功后计时。
- **回归入口与必测分支**：[subscription_triggers_test.dart](../../test/xboard/services/subscription_triggers_test.dart)验证门控、事件/计时替身和API调用计数；实际OS恢复事件、旧账号失效与失败后再进入须设备/真实provider验证。
- **限制／状态**：原D07：失败也可能消耗24小时窗口，未在本轮修复；原G01：provider没有读取持久SubscriptionCache的生产路径，不能称已支持离线账号恢复。

<a id="f25"></a>
### F25 公告、未读与弹窗生命周期

- **归类／要求**：自有。保留当前公告和已读能力；历史只授权修销毁后Ref与重复弹窗，退出后的迟到公告明确暂缓（REQ-NOTICE）。
- **原版0.9.2**：原版没有面板公告/按账号已读表，不与原版更新通知混同。
- **当前品牌实现**：[notice_provider.dart](../../lib/xboard/providers/notice_provider.dart)要求ready/已登录，获取失败当空列表；[notice_read_store.dart](../../lib/xboard/util/notice_read_store.dart)按当前认证Token的SHA256前8位保存已读（空Token或读取异常回退anon），不是稳定账号ID，弹窗入口有实例打开状态与mounted检查。
- **依赖／平台／接缝**：输入F01/F05/F03/F14；显示依赖F21；Token分区随认证值变化；同账号重登且Token改变时可能重新未读，不承诺每次登录必然重现；分区不等于所有迟到UI回调都有会话门禁。无公告专用底座接缝。
- **回归入口与必测分支**：[已读存储](../../test/xboard/util/notice_read_store_test.dart)、[打开生命周期](../../test/xboard/widgets/notice_open_lifecycle_test.dart)、[正文HTML](../../test/xboard/golden/notice_content_html_test.dart)；弱网、销毁、重复点击、退出后回调分别核对。
- **限制／状态**：UB-GAP-09为用户暂缓的退出后迟到公告问题，不能在升级中自动加入会话保护或标为已解决。

<a id="f26"></a>
### F26 邀请、佣金、提现与分享链接

- **归类／要求**：自有。保留现有商业业务；接口写入不自动套用读取重试（REQ-API）。渠道与金额细节取CONTRACTS，未明确的新业务规则不由文档推断。
- **原版0.9.2**：原版没有邀请返佣或ShareLink。
- **当前品牌实现**：[invite_provider.dart](../../lib/xboard/providers/invite_provider.dart)加载邀请信息、佣金记录及提现配置；分享页复制链接到剪贴板，未接系统分享面板；信息中无邀请码且provider仍有效时会自动调用generateInviteCode，成功后重拉，进入页面可能触发写操作；[invite_commission_page.dart](../../lib/xboard/pages/invite_commission_page.dart)与[commission_records_page.dart](../../lib/xboard/pages/commission_records_page.dart)消费；[share_link_provider.dart](../../lib/xboard/providers/share_link_provider.dart)为guest接口，enabled=false是正常未配置态。
- **依赖／平台／接缝**：输入F03/F05/F14；分享页面[share_friend_page.dart](../../lib/xboard/pages/share_friend_page.dart)可不依赖登录。邀请码创建状态按SDK会话隔离，但内存中的写结果待核对状态不提供重启/跨设备幂等。无专用底座接缝。
- **回归入口与必测分支**：[invite_request_lifecycle_test.dart](../../test/xboard/providers/invite_request_lifecycle_test.dart)、[invite_dispatch_recovery_test.dart](../../test/xboard/sdk/invite_dispatch_recovery_test.dart)、[commission_amount_http_test.dart](../../test/xboard/sdk/commission_amount_http_test.dart)、[commission_input_test.dart](../../test/xboard/pages/commission_input_test.dart)。
- **限制／状态**：字段/并发回归不等于真实提现到账、剪贴板交互或后端支付链成功；没有专属ShareLink设备证据时保持待验。

<a id="f27"></a>
### F27 首页实时流量与速度单位

- **归类／要求**：自有展示+复用流量provider。维护约束：实际实时流量、套餐额度和节点延迟不能混为同一指标；单位转换依据当前代码，不将界面标签当原始单位。
- **原版0.9.2**：原版`lib/providers/app.dart`的Traffics维护流量序列，来自Core流量读取。
- **当前品牌实现**：[xb_traffic_adapter.dart](../../lib/xboard/shell/adapters/xb_traffic_adapter.dart)读取trafficsProvider.list.last，空列表用0；[xb_speed_card.dart](../../lib/xboard/shell/tabs/home/xb_speed_card.dart)将字节/秒乘8转换为Kbps/Mbps，首页延迟另读F12独立状态。
- **依赖／平台／接缝**：输入底座Traffics，F08运行切换影响流量源；依赖F21布局。FA-traffics为直接复用锚点，图标/布局变化不应改单位或样本选择。
- **回归入口与必测分支**：[xb_traffic_adapter_test.dart](../../test/xboard/shell/adapters/xb_traffic_adapter_test.dart)、首页布局/延迟测试；真实Core采样、断开后归零与低速阈值需分别核对。
- **限制／状态**：Provider替身测试不证明真实吞吐；不把速率与接口返回的累计流量/套餐剩余互换。

<a id="f28"></a>
### F28 品牌浏览器UA与底座globalUa

- **归类／要求**：自有HTTP政策+复用底座通用UA。品牌管理流量按平台固定浏览器UA，用户已撤销强制覆盖底座globalUa；撤销覆盖的出处为REQ-IPV6及PATCHES接缝点#7（2026-06-09历史决定）。三条链分别按实际消费者核对，不以UA策略承诺网络可达。
- **原版0.9.2**：原版`lib/state.dart`的GlobalState.ua读取patchClashConfig.globalUa并回退packageInfo.ua，B1-globalua定位此getter。
- **当前品牌实现**：[xboard_user_agent.dart](../../lib/xboard/config/xboard_user_agent.dart)为SDK、Bootstrap、密文下载、探针/更新业务通道提供current；[xboard_release_dio.dart](../../lib/xboard/services/xboard_release_dio.dart)与module配置SDK。底座GlobalState.ua并不是XboardUserAgent.current的别名；第三条链是[lib/common/constant.dart · browserUa](https://github.com/chen08209/FlClash/blob/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7/lib/common/constant.dart)，品牌exit_ip_probe直接使用它，固定浏览器字符串不随品牌UA切换。
- **依赖／平台／接缝**：输入平台身份，作用F02/F03/F06/F14/F16/F18（教程回退阅读器也使用品牌UA）；B1-globalua只标底座依赖。浏览器实际请求与第三方SDK不保证使用该Dart UA。
- **回归入口与必测分支**：[xboard_user_agent_test.dart](../../test/xboard/config/xboard_user_agent_test.dart)、bootstrap同步配置和HTTPS路由测试；检查具体生产消费者而非只断言字符串。
- **限制／状态**：固定UA值取源码，不在文档复制版本；远端UA模板当前未接入，不因上游默认UA更新直接覆盖品牌通道。

## 平台兼容与支持范围

以下是源码声明与历史成品观察的边界，不是覆盖全部系统版本的实测认证；成品和设备结果唯一见Docs/STATUS。构建工具版本取native_toolchain/锁文件，不能把compileSdk、Runner系统或部署目标单独当作用户设备兼容结论。两个品牌共用平台链，但各自身份/签名/资源仍需验收。

| 平台 | 当前发行目标/格式 | 源码门槛与依赖 | 实测与待确认 |
| --- | --- | --- | --- |
| Android | ARM64-v8a、armeabi-v7a APK；不发行x86 | [Gradle](../../android/app/build.gradle.kts)的app minSdk继承`flutter.minSdkVersion`，core/service/common及gomobile的当前下限配置为24；targetSdk/compileSdk当前均为37，由版本目录管理；它们不是最低系统版本。最终merged manifest和APK ABI/版本码/签名才是安装判据 | 历史A的#141双APK已确认minSdk24；证据与设备边界见Docs/STATUS；不能用compileSdk37称“必须Android37”，也不能承诺任意32位设备可装 |
| Windows | AMD64 setup.exe | [Inno](../../windows/packaging/exe/inno_setup.iss)声明MinVersion=10.0；[VC策略](../../tool/windows/vc_runtime.json)及原生库共同约束运行条件，教程/客服WebView依赖分别核对 | 不支持Win7的当前安装入口；不能从10.0推定所有Win10发行版都已实测；Windows ARM64未纳入正式矩阵 |
| macOS | AMD64、ARM64 DMG | [Xcode工程](../../macos/Runner.xcodeproj/project.pbxproj)部署目标12.0，Info.plist继承该值；插件/最终Mach-O最低版本仍需成品核验 | macOS12是工程声明，不是全系统实测；当前无本轮Mac实机记录，Gatekeeper/Keychain及插件行为待验 |
| Linux AMD64 | AppImage、DEB、RPM | [DEB依赖](../../linux/packaging/deb/make_config.yaml)：ayatana-appindicator、libsecret、WebKitGTK4.1、libsoup3、libcurl；[RPM](../../linux/packaging/rpm/make_config.yaml)声明libsecret/WebKit/libsoup/libcurl，尚未声明appindicator；包名和可运行性需目标发行版验证。实际ELF/glibc和打包库另验 | 不宣称所有Linux通用；Runner Ubuntu22.04是打包基线，不是所有用户发行版的保证。AppImage客服使用浏览器，仍不能推断整个包无系统依赖 |
| Linux ARM64 | AppImage、DEB；无ARM RPM | 架构专属原生库/ELF及实际包依赖；GitHub原生目标，VDS模拟构建路线退役 | 无本轮原生设备兼容矩阵；不得在x64宿主测试通过后写ARM64设备通过 |
| iOS / Windows ARM64 | 无当前正式发行目标 | iOS插件源码、后台架构枚举或工具候选不等于可发布客户端 | 未承诺支持；恢复目标须独立评估与授权 |

升级或更换工具链时重新核对：Android合并清单和设备ABI、Windows安装器及PE运行库、macOS各架构Mach-O/插件部署目标、LinuxELF解释器/glibc和动态依赖，再做对应设备验证。结果只更新实际版本/发行版范围，不把单台成功扩大成整个平台认证。

## 两品牌与平台依赖矩阵

### 品牌维度：共享实现不等于身份可共用

| 检查对象 | 品牌A / OmoFly | 品牌B / 袋鼠加速 | 唯一来源与检查方式 |
| --- | --- | --- | --- |
| F01—F28业务规则 | 同一套品牌业务代码 | 同一套品牌业务代码 | 本文各F项；测试名带brand_a/b不能单独证明使用了真实发布配置 |
| 包名、scheme、服务、目录、默认端口 | 独立A身份 | 独立B身份；不允许中文的内部标识使用daishu | [brands.json](../../tool/identity/brands.json)、[brand_identity.dart](../../tool/brand_identity.dart)，逐品牌检查注入结果；不在本文复制常量值 |
| 显示名、图标、字体 | A显示名/资源 | B中文显示名/资源及必要ASCII名称 | [图标校验](../../tool/test/system_icon_assets_test.dart)、[品牌B Android源资源回归](../../tool/test/android_brand_icon_resources_test.py)（不覆盖A及最终包全部图标）、[Windows标题](../../tool/test/windows_title_encoding_test.py)；显示名与包名不同层 |
| API、Bootstrap/fallback、客服标识 | A受限输入 | B受限输入 | flavor/Secrets按构建授权取得；本文不记录端点、密码或Token。最终包用[check_fallback_assets.py](../../tool/check_fallback_assets.py)验证，不能拿A输入替B |
| 原签名/升级/内部编号 | 本品牌旧包连续性 | 本品牌旧包连续性 | 最终APK签名和versionCode、Windows安装身份、macOS Bundle ID；对应[品牌正式契约](../../tool/check_android_release_contract.py)和F19。原证书验签缺口见UB-GAP-08；产品版本/底座版本/Actions序号不是同一个编号 |
| Android内部码 | 同品牌产品构建号加策略偏移 | 同品牌产品构建号加策略偏移 | [android_version_policy.json](../../tool/android_version_policy.json)当前offset=1000000；旧main源码直接赋flutter.versionCode，但旧最终APK仍须读取实际ABI输出；不把产品build、原生码和Sentry release当一个值 |
| 跨分支编号唯一性 | 目标为同品牌全发布历史唯一 | 目标为同品牌全发布历史唯一 | 当前仅源分支内安全回写，未实现全局预留；B的#132/#146重复build35已核对。UB-GAP-07登记代码待办，本轮不改分配器；合并取max只防回退，不保证并发唯一 |
| Sentry release与符号 | A发布身份 | B发布身份 | [项目检查](../../tool/test/sentry_projects_test.py)、每目标构建证据；只读核对当前结果见STATUS，不复制数量到本表 |
| 数据迁移及清理 | 仅A可证明归属的记录/目录 | 仅B可证明归属的记录/目录 | F05/F19/F20；A/B/原版三者并存、退出、卸载交叉负控，不能按进程显示名推断所有权 |

### 各平台安装/退出边界

P01—P07对应系统入口、原版依赖与品牌差异。四个正式平台均检查F01—F28；Linux按格式、macOS按架构拆分原生验收。下表只记录不同点，避免将同一业务政策复制四遍。

| ID / 平台 | 原版0.9.2依赖入口（相对原版根；固定commit见上） | 当前品牌接入／必须保持 | 回归入口与原生验收 |
| --- | --- | --- | --- |
| P01 Android ARM64 / ARMv7 | `android/app/src/main/kotlin/com/follow/clash/MainActivity.kt`、`android/app/src/main/kotlin/com/follow/clash/ServiceController.kt`、`android/app/src/main/kotlin/com/follow/clash/TileService.kt`；`lib/core/lib.dart`的CoreLib（由CoreController选择）；Gradle及gomobile | F01/F08沿Service/VPN生命周期；F19用品牌applicationId与运行通道，AGP兼容和sourceSet资源独立；F16增加ApkInstallerPlugin，系统安装界面接管，不提前保证安装完成；F17原生Crisp；F18平台WebView | [Android身份/通道](../../tool/test/android_brand_identity_test.dart)、[真实Gradle身份/AGP兼容](../../tool/test/android_brand_identity_gradle_test.py)、[真实Flutter插件版本码](../../tool/test/android_version_gradle_test.py)、[APK资源契约](../../tool/check_android_release_contract.py)。设备必须覆盖旧正式包更新、权限拒绝、后台/磁贴、VPN断连、客服；不发行x86 |
| P02 Windows AMD64 | `windows/runner/main.cpp`、`lib/core/service.dart`的CoreService、`lib/providers/actions/system.dart`、`lib/common/proxy.dart`、`services/helper`、Inno模板 | F08/F13借Core/Helper和系统代理；F19提前数据目录锁及专属服务；F16按原版准备/安装后/卸载顺序替换品牌名；MinVersion=10.0、CloseApplications/RestartApplications为品牌显式声明，原版v0.9.2未声明，不将未声明解释为Inno默认禁用。品牌额外VC门禁、可选安全数据清理、WebView退出修复保留；不再增加用户已拒绝的服务路径/最终进程复查 | [原版事件顺序](../../tool/test/windows_upstream_installation_test.py)、[VC原生进程](../../tool/test/windows_vc_runtime_process_test.ps1)、[目录安全删除](../../tool/test/windows_brand_data_cleanup_test.ps1)、[WebView退出](../../tool/test/windows_webview_shutdown_test.py)。原生Windows需覆盖中文路径、已运行覆盖/取消、Helper、代理及junction竞争 |
| P03 macOS AMD64 | `lib/core/service.dart`的CoreService、`macos/Runner/AppDelegate.swift`、`macos/Runner/MainFlutterWindow.swift`、`macos/Runner/Info.plist`、`macos/Runner.xcodeproj/project.pbxproj`中的FlutterGeneratedPluginSwiftPackage；原版快照没有Podfile、系统退出 | F19 Bundle ID/Keychain/偏好目录/显示名注入；F16浏览器下载DMG，不使用Android/Windows安装器；F17桌面WebView窗口聚焦，F18教程WebView；F22 dSYM及单架构库 | [macOS成品清单](../../tool/test/macos_final_inventory_test.py)、[符号回执](../../tool/test/sentry_macos_receipt_validation_test.py)、[存储恢复](../../test/xboard/sdk/token_storage_recovery_test.dart)。原生Keychain、Gatekeeper、Finder/Dock、覆盖安装和退出待设备证据 |
| P04 macOS ARM64 | 与P03入口共用，但原生运行库和符号必须是ARM64 | 不能将AMD64清单/测试结果当ARM64结果；原版亦有声明12与部分Mach-O minOS13矛盾，用户要求系统支持跟随原版，不擅自改门槛 | 与P03相同入口按ARM64独立跑；对照原版实际成品及macOS12/13设备，具体矛盾见UB-GAP-03对应STATUS，不能用Xcode部署目标代替成品检查 |
| P05 Linux AppImage AMD64 / ARM64 | `linux/runner/my_application.cc`、`lib/core/service.dart`的CoreService、`lib/providers/actions/system.dart`、`lib/common/path.dart`、`services/helper/src/service/linux.rs` | F19品牌应用/Helper/单实例/目录；F16当前按APPIMAGE环境变量选择替换目标，尚未核验当前进程归属（UB-GAP-20），启动失败恢复并重启旧版，失败恢复及成功交接后均可能保留备份，未有统一清理策略；F17浏览器环境净化及格式识别，F18仍有回退阅读器。ARM64正式构建走GitHub，VDS路线已退役 | [AppImage重启](../../tool/test/appimage_restart_test.py)、[浏览器环境](../../tool/test/crisp_appimage_browser_test.dart)、[品牌原生路径](../../tool/test/brand_data_runtime_test.py)。真实AppRun、系统代理/Helper、HOME符号链接、外链子进程与新旧进程交接另验；两个架构ELF各查 |
| P06 Linux DEB / RPM | 同Linux底座：`linux/runner/my_application.cc`、`lib/core/service.dart`、`lib/providers/actions/system.dart`、`lib/common/path.dart`、`services/helper/src/service/linux.rs`；另有`linux/packaging/deb`、`linux/packaging/rpm` | 客服继续内嵌WebKit，教程回退行为不变；共享Linux下载代码不等于支持包管理器自动覆盖，自替换要求APPIMAGE，非该运行方式可能返回installFailed并提示手动安装。RPM现行仅AMD64 | [WebView身份](../../tool/test/linux_webview_identity_test.py)、[原生发行迁移](../../tool/test/native_release_migration_test.py)；真实包依赖、安装/卸载、systemd及WebKit辅助进程须目标发行版验收，不能套AppImage浏览器结论 |
| P07 iOS / Windows ARM64 | 仓内可能存在iOS工程/移动插件及平台枚举 | 当前正式workflow无这两个发行目标；只核对共享改动会否破坏保留源码，不因为有枚举就接入新平台 | 工具链、原生依赖、签名/打包与设备测试均待单独评估授权；没有测试入口或证据时标待确认，不列通过 |

安装/退出是不同平台契约：Windows用户取消向导不应提前退出客户端；Android调起安装器不等于安装完成；macOS网页打开不等于DMG已安装；AppImage旧进程退出与新版exec/回滚需单独确认。系统退出仍复用原版，不引入U05的额外严格协议。

## 接缝与复用锚点索引

本表只把既有登记关联到行为ID，不新增/调整/退役实际接缝。`SEAM-*`为已登记接入，`A/B/FA-*`含纯定位或复用符号，不能混称接缝数量；没有专用锚点的依赖用文件/符号定位，不能为了填表虚构新ID。机器数据和完整授权/历史只维护在Docs/PATCHES、FLCLASH_ANCHORS。

| 索引组 → 行为 | 既有文件/入口与锚点 | 升级/退役判据 |
| --- | --- | --- |
| S01 启动/HTTP → F01/F02/F04/F14/F15/F22 | `lib/main.dart`：`SEAM1-httpoverrides`、`SEAM1-runapp`、`SEAM-sentry-startup`、`A1-globalstate-init`、`A4-init-error`、`E1-fluttererror-onerror`；`lib/bootstrap.dart`：`A5-providercontainer`、`SEAM-bootstrap-update`、`SEAM-bootstrap-welcome`；`B1-globalua`仅定位原版GlobalState.ua（F28），不是品牌浏览器UA；首次TLS默认也是该既有初始化接缝中的调用 | 容器、网络override、监控、迁移和品牌异步阶段顺序不能丢；上游有相似启动恢复不代表品牌fallback/更新门禁可删 |
| S02 身份/存储 → F01/F05/F19/F20 | `SEAM-instance-entry`、`SEAM-instance-lock`、`SEAM-bootstrap-lock`、`SEAM-brand-support-root`、`SEAM-profile-db-open`；`lib/common/lock.dart`、`lib/common/path.dart`、`lib/database/database.dart` | 只有原版在品牌数据目录、跨安装路径、多进程与busy/重试契约全部满足后才评估退役；需原生锁/迁移负控，不仅单进程单元测试 |
| S03 Profile/连接/节点复用 → F06/F08/F10/F12 | `B3-putprofile`、`B4-deleteprofile`、`B5-addprofileformurl`、`B8-profiles-put`、`B8-profiles-del`、`C3-currentprofileid`、`FA-proxiestabstate`、`FA-isstart`、`FA-corestatus-provider`、`FA-corestatus-enum`、`B6-profile-normal`、`FA-startbutton`；`FA-proxygroupview`与`FA-proxycard`是原版页面参照，品牌节点不直接复用这两个Widget | 多数是复用锚点，不意味着修改上游方法。返回值、失败回滚、延迟应用及selectedMap变化时，先审对应F项，不强行保留旧底座实现 |
| S04 模式 → F09/F10/F11 | `SEAM-brand-mode-menu`、`SEAM-brand-mode-default`、`SEAM-brand-mode-write`、`SEAM-brand-mode-load`；`FA-changemode`仅定位原版执行 | 上游仍三态时品牌二态政策必须保留；若上游提供等价可配置策略，验证所有旁路入口后再决定合并/退役 |
| S05 平台身份/Helper → F13/F16/F19 | `SEAM-brand-constants`、`SEAM-brand-protocol`、`SEAM-brand-default-port`、`SEAM-brand-helper-binary`、`SEAM-brand-windows-helper`、`SEAM-brand-helper-registry`、`SEAM-brand-linux-helper`、`SEAM-brand-linux-webkit`；原生Manifest/Runner/安装器另见PATCHES品牌注入记录 | 同名字段不等于同一用途。必须分别核对进程、锁、目录、服务、scheme、端口和窗口系统标识；不能将显示名替换当隔离完成 |
| S06 构建/资源/符号 → F02/F16/F17/F19/F22 | `SEAM-android-plugin-compat`、`SEAM-sentry-gomobile`、`SEAM-sentry-go-hook`、`SEAM-sentry-windows-rust`、`SEAM-native-output-encoding`、`SEAM-native-cache-content`、`SEAM-native-helper-toolchain`、`SEAM-sentry-rust-profile`、`SEAM-sentry-helper-profile`、`SEAM-sentry-linux-symbols`、`SEAM-sentry-linux-runtime-copies`、`SEAM-sentry-macos-pods`、`SEAM-sentry-macos-runner`、`SEAM-sentry-windows-c-language`、`SEAM-sentry-windows-symbols`；Android #4系列sourceSet及身份注入 | 原生hook环境/空缓存/中文路径/行尾/最终资源必须从正式入口验证；资源或符号生成器迁移后，不能只保留旧文件名或放宽清单检查 |
| S07 Windows安装/卸载 → F16/F19/F20 | `SEAM-windows-vc-runtime`、`SEAM-windows-prepare-chain`、`SEAM-windows-owned-data-cleanup`、`SEAM-windows-uninstall-data-gate`；`windows/packaging/exe/inno_setup.iss` | 常规关闭/Helper/遗留代理跟随原版；品牌VC门禁和用户数据所有权保护不是同一件事。不能以“精简安装器”为由删除安全数据边界 |
| S08 客服/教程窗口 → F16/F17/F18/F22 | `SEAM-crisp-focus-windows`、`SEAM-crisp-focus-linux`、`SEAM-crisp-focus-macos`、`SEAM-tutorial-webview-shutdown`、`SEAM-tutorial-mutex-compat`；window插件/CMake | 上游或插件恢复同等聚焦、销毁及互斥接口后才考虑退役；需窗口实际打开/重复点击/退出测试，而非只有依赖版本能解析 |
| S09 外壳/主题 → F21及各页面 | `SEAM9-home`、`D3-navitem-freezed`、`D4-pagelabel-enum`；`FA-toolsview`为F23保留但未找到生产调用的适配方法参照；`FA-traffics`是F27直接使用的provider；`lib/manager/window_manager.dart`与`lib/common/window.dart`既有品牌窗口记录 | 原版主界面改版不自动覆盖品牌Home/Nodes/Mine；ThemeMode.system已复用；用户字体选择衔接缺口见F21/UB-GAP-19，不能把Material默认字体继承写成完整复用上游字体，不重新增加旧主题默认补丁 |

## 未使用功能与待核对的间接影响

U项同时列出明确暂缓的品牌增强，但不把已使用的底座能力归为未使用；尤其U04保留底座恢复入口，U05保留正常退出，详见各行。

| ID / 分类 | 用户要求与当前源码事实 | 影响链、回归及处理 |
| --- | --- | --- |
| U01 原版仪表盘布局：未使用 | 品牌使用Home/Nodes/Mine外壳；不自动采用上游`lib/views/dashboard/dashboard.dart`布局 | 仍共享actions、theme、状态和设置；查F08—F13/F21、S09。上游只改布局可不接入，改provider则必须继续追踪 |
| U02 上游IP探测展示/缓存：未使用于品牌卡片 | F11使用Dio七源，原版`lib/providers/outbound_ip.dart`和`lib/providers/routed_probe.dart`保留给其他消费者 | RouteTracker仍是F11依赖；上游缓存/初始化改动可能间接触发品牌重测，不能把整组IP模块判成无关。以exit_ip_lifecycle回归和真实路由事件核对 |
| U03 隐藏超时节点：用户不需要，但存在间接影响 | 用户要求不接入；[proxies状态](../../lib/providers/state/proxies.dart)的filterGroupsState→visibleGroupsState→_hideTimeoutProxies仍读配置，品牌nodesView消费该链 | 后续已含该字段的配置或F23完整备份恢复可带入true；选中项保留，通常减少非选中超时节点，首页回退项需单独验证（UB-GAP-04）；列为已知源码影响、未修复，非期望规则。下一步需真实provider+旧配置回归，不能只用默认false替身；本轮不改实现 |
| U04 统一备份恢复协调：明确暂缓 | 用户暂不处理把BackupAction恢复、回滚与订阅写入统一协调的方案；底座`lib/providers/actions/backup.dart`的BackupAction仍被使用，未接入的是品牌统一协调覆写，不是恢复功能本身 | 仍依赖底座数据库/目录/恢复格式。审F06/F20和原版BackupAction，但不擅增恢复覆写接缝；现有写入队列不覆盖全部恢复路径 |
| U05 严格退出握手/安装全局门禁：明确不采用 | 用户选择跟随原版`windows/packaging/exe/inno_setup.iss`及`lib/providers/actions/system_exit.dart`的正常清理/退出，取消额外服务路径核验、结束进程复查等保护 | 按F16/P02/S07核对上游事件和品牌身份；保留已接受边界，不能借升级重新加入被拒绝设计。AppImage自替换恢复是另一个已授权能力，不随之删除 |
| U06 非正式平台：未交付 | iOS及Windows ARM64不在当前正式发行矩阵；存在工程或架构枚举不构成支持承诺 | 按P07检查共享影响；新增目标先评估工具链、原生依赖和签名，再取得授权，不能靠套用其他平台测试判通过 |

## 缺口索引与证据边界

以下只关联行为ID和影响，实时状态及关闭证据唯一维护在Docs/STATUS/CONTRACTS；不在这里另维护“全通过”表。

| 局部缺口 | 相关行为／平台 | 当前状态维护入口 |
| --- | --- | --- |
| UB-GAP-01 | F01/F05/F08/F19/F22 | 当前状态与关闭条件统一见[STATUS缺口索引](https://github.com/wvjh3z/proxy-suite-docs/blob/main/STATUS.md#基线局部缺口与发布待办)，不在本表另行更新进度 |
| UB-GAP-02 | F09,F11 | 当前状态与关闭条件统一见[STATUS缺口索引](https://github.com/wvjh3z/proxy-suite-docs/blob/main/STATUS.md#基线局部缺口与发布待办)，不在本表另行更新进度 |
| UB-GAP-03 | P03/P04/P05/P06 | 当前状态与关闭条件统一见[STATUS缺口索引](https://github.com/wvjh3z/proxy-suite-docs/blob/main/STATUS.md#基线局部缺口与发布待办)，不在本表另行更新进度 |
| UB-GAP-04 | F10 | 当前状态与关闭条件统一见[STATUS缺口索引](https://github.com/wvjh3z/proxy-suite-docs/blob/main/STATUS.md#基线局部缺口与发布待办)，不在本表另行更新进度 |
| UB-GAP-05 | F06,F20 | 当前状态与关闭条件统一见[STATUS缺口索引](https://github.com/wvjh3z/proxy-suite-docs/blob/main/STATUS.md#基线局部缺口与发布待办)，不在本表另行更新进度 |
| UB-GAP-06 | F07 | 当前状态与关闭条件统一见[STATUS缺口索引](https://github.com/wvjh3z/proxy-suite-docs/blob/main/STATUS.md#基线局部缺口与发布待办)，不在本表另行更新进度 |
| UB-GAP-07 | F19/F22；品牌编号矩阵 | 当前状态与关闭条件统一见[STATUS缺口索引](https://github.com/wvjh3z/proxy-suite-docs/blob/main/STATUS.md#基线局部缺口与发布待办)，不在本表另行更新进度 |
| UB-GAP-08 | F19；品牌签名矩阵 | 当前状态与关闭条件统一见[STATUS缺口索引](https://github.com/wvjh3z/proxy-suite-docs/blob/main/STATUS.md#基线局部缺口与发布待办)，不在本表另行更新进度 |
| UB-GAP-09 | F25 | 当前状态与关闭条件统一见[STATUS缺口索引](https://github.com/wvjh3z/proxy-suite-docs/blob/main/STATUS.md#基线局部缺口与发布待办)，不在本表另行更新进度 |
| UB-GAP-10 | F13b,F23 | 当前状态与关闭条件统一见[STATUS缺口索引](https://github.com/wvjh3z/proxy-suite-docs/blob/main/STATUS.md#基线局部缺口与发布待办)，不在本表另行更新进度 |
| UB-GAP-11 | F23 | 当前状态与关闭条件统一见[STATUS缺口索引](https://github.com/wvjh3z/proxy-suite-docs/blob/main/STATUS.md#基线局部缺口与发布待办)，不在本表另行更新进度 |
| UB-GAP-12 | F19/F21；Android应用内logo | 状态与关闭条件唯一见[STATUS](https://github.com/wvjh3z/proxy-suite-docs/blob/main/STATUS.md#基线局部缺口与发布待办) |
| UB-GAP-13 | F19/P01；Android TV资源和范围 | 状态与产品待确认项唯一见[STATUS](https://github.com/wvjh3z/proxy-suite-docs/blob/main/STATUS.md#基线局部缺口与发布待办) |
| UB-GAP-14 | F01/F08/F23；P01—P06非首页启停 | 当前原生调用已存在；是否额外约束待确认，见[STATUS](https://github.com/wvjh3z/proxy-suite-docs/blob/main/STATUS.md#基线局部缺口与发布待办) |
| UB-GAP-15 | F19/P01；品牌B Android启动器/通知应用图标 | 状态与设备验收统一见[STATUS](https://github.com/wvjh3z/proxy-suite-docs/blob/main/STATUS.md#基线局部缺口与发布待办) |
| UB-GAP-16 | F01/F06/F08 | 启动守卫与品牌订阅同步风险，状态唯一见[STATUS](https://github.com/wvjh3z/proxy-suite-docs/blob/main/STATUS.md#基线局部缺口与发布待办) |
| UB-GAP-17 | F06/F19/F23 | 深链导入外部入口，状态见同一STATUS索引 |
| UB-GAP-18 | F19/F20 | Android文档提供器，状态见同一STATUS索引 |
| UB-GAP-19 | F21/S09 | 字体选择与品牌主题衔接；状态和关闭条件见STATUS，不以默认主题对照替代选择字体验收 |
| UB-GAP-20 | F16/P05/P06 | AppImage更新目标仅由环境变量指定；风险与关闭条件见STATUS |


已修复过的漏洞应成为回归条件，不成为必须复制的旧行为：全局GLOBAL被二次过滤、暂停显示为已连接、点击读取旧认证、旧异步结果串会话、IP结果被迟到通知清空、数据库中断迁移不可重入。各自测试入口已在F项登记；本轮没有重新跑这些Flutter或原生测试，不以文档完善关闭任何设备问题。

## 使用与维护入口

升级步骤、差异映射和补丁退役规则只维护在[UPGRADING](UPGRADING.md)；命令/测试框架只维护在[WORKFLOWS](WORKFLOWS.md)；可合并与可发布条件只维护在[ACCEPTANCE](ACCEPTANCE.md)，升级材料位置和保留规则只维护在[MATERIALS](MATERIALS.md)。下表仅说明各现有测试覆盖哪一层，不再次规定执行流程。

## 回归入口层级：存在、覆盖与实际执行分开

F项列出的“必测分支”是升级验收目标，不表示所列文件已经覆盖全部场景；缺口必须追加测试或安排原生/设备验收。下面说明已反查的关键入口性质，本轮只读核对，没有重跑这些测试。

| 入口类型／实例 | 实际覆盖层 | 覆盖边界（执行方法统一见WORKFLOWS） |
| --- | --- | --- |
| `test/xboard/bootstrap_sync_phase_test.dart` | XboardModule同步接线，SDK/存储有替身 | Flutter套件；不能代替真实SDK网络或原生首次启动 |
| `test/xboard/config/xb_mode_hotkeys_test.dart` | 真HotKeyManager处理注入的事件流，真实品牌配置政策 | 证明Dart侧循环/旧direct归一，不等于操作系统快捷键注册及托盘原生交互已验 |
| `test/xboard/shell/tabs/exit_ip_lifecycle_test.dart`、`test/xboard/widgets/tutorial_linux_navigation_test.dart` | provider/Widget时序；包含品牌参数和平台主题/覆盖 | 本轮未运行；前者探测结果替身、后者Linux平台模拟不能代替真实网络或Linux桌面 |
| `test/xboard/services/xb_update_https_routing_test.dart` | 回环HTTPS/CONNECT及生产Dio策略 | 真实本地连接与证书夹具；不连接生产API，不代表所有用户运营商/系统路由 |
| `tool/test/android_brand_identity_gradle_test.py` | 实际Gradle/AGP的身份DSL和插件兼容 | 不是版本码专项；在准备好JDK/Gradle的授权主机运行，不能因.py而称轻量本地检查 |
| `tool/test/android_version_gradle_test.py` | 真实Flutter Gradle插件、AGP单/双ABI版本码及旧策略负控 | 正式workflow单列调用；不是最终APK签名/清单读取，后者另由check_android_release_contract检查 |
| `tool/test/crisp_appimage_browser_test.dart` | 直接执行生产格式识别/环境净化及真实无害子进程 | 独立main脚本，不是testWidgets；[distributor_preflight.py](../../tool/distributor_preflight.py)使用打包工具包图；实际命令见WORKFLOWS的回归入口选择 |
| `tool/test/windows_upstream_installation_test.py` | 安装器顺序结构/负控，加Windows限定的MSVC代理政策fixture | 非Windows会跳过native项；Python部分通过不等于真实ISCC安装、取消或卸载通过 |
| `tool/test/appimage_restart_test.py` | Linux下提取并执行实际重启脚本、无害进程、恢复/等待分支 | 不构建客户端，但依赖Linux/proc；脚本回归不代表新版Flutter实例启动成功 |
| `test/xboard/services/geo_update_completion_test.dart` | 请求应答、匹配资源完成、错误/超时及监听移除 | 注入事件验证；不是七天全调度或真实Geo下载验收 |
| 成品脚本/原生设备 | APK资源签名/版本、PE、Mach-O、ELF、系统服务、WebView及真实业务 | 按各P项分别取得品牌/架构证据；这里只提供入口，不声明本轮执行或自动关闭G项 |

## 第三方依赖对应关系

Dart依赖的实际解析版本取[pubspec.lock](../../pubspec.lock)，直接约束取[pubspec.yaml](../../pubspec.yaml)；原生部分另核对Gradle/Pod/Swift/CMake及[native_toolchain.json](../../tool/native_toolchain.json)。版本锁定、源码测试、最终入包是三层证据，不能仅更新Dart版本表。

| 依赖 | 品牌/底座使用关系 | 行为编号及升级检查 |
| --- | --- | --- |
| material_ui | 上游组件基础，品牌也直接使用 | F07/F18/F21/F23；主题、字体继承、导航/弹窗和渲染资源 |
| flutter_riverpod | 两层共享状态、监听和生命周期 | F01/F03—F12/F15/F24—F27；自动重试、dispose、watch/listen、旧会话有效性 |
| flutter_secure_storage | 品牌Token存储 | F05/F19/F20；原生后端、读写验证、Keychain与持久降级 |
| sentry_flutter | 品牌监控 | F01/F22；启动偏好、原生捕获、debug ID及匹配符号 |
| flutter_inappwebview及平台包 | 品牌教程 | F18/F16；注册、数据目录、WebView2、C++退出资源及原生依赖 |
| desktop_webview_window / crisp_chat | 品牌桌面/移动客服；本地crisp_chat兼容副本 | F17/F19/F22；窗口聚焦/销毁、原生SDK版本、Android资源；AppImage仍外部浏览器 |
| connectivity_plus | 宿主及品牌网络观察 | F04/F13/F24；集合事件、未知/错误、桌面服务及VPN标记 |
| drift / sqlite3 | 底座主库与品牌外挂库 | F06/F20/F23；schema21与schema2分别迁移、原生锁/隔离线程/备份格式 |
| cryptography | 品牌密文及存储降级保护 | F02/F05/F06；算法/编码/tag验证和错误处理，不能仅验证能解某个样例 |
| path_provider / shared_preferences | 共享路径和配置；品牌加归属/首次默认 | F01/F02/F05/F13/F14/F16/F17/F19/F20/F22/F24/F25；原生路径、缓存/落盘、账号与品牌隔离 |
| dio | 品牌HTTP、订阅、更新及IP请求 | F02/F03/F06/F11/F14/F15/F16/F18；适配器、超时、证书及取消 |
| url_launcher | 品牌客服/教程/支付等外部跳转 | F07/F15/F16/F17/F18/F25；平台支持、失败回退与进程环境 |
| flutter_html / html | 品牌HTML展示与解析 | F18/F25/F07；链接回调、渲染与输入兼容 |
| emoji_regex | 品牌文字与emoji分段 | F07/F18/F21/F25；Unicode匹配及字体回退 |
| drift_flutter | 品牌外挂数据库接入 | F20；打开路径、迁移与原生依赖，区别底座主库 |
| crypto | 品牌摘要计算 | F05/F06/F17/F20/F24/F25；会话清理、订阅owner/缓存、客服身份及公告Token分区，不等于加密 |
| yaml | 品牌订阅解析 | F06；格式、错误与兼容性 |
| path | 品牌路径处理 | F17/F18/F19/F20；客服/教程资源路径、归属与数据库目录 |
| qr | 上游共享二维码组件 | F07；品牌实际QrCodeView渲染在order_payment_page.dart，checkout_outcome_ui.dart是结果模型；分享和F23实际入口未使用二维码，不据上游组件可用性扩大归属 |

## 用户决定的出处

“归类／要求”中的产品决定按下表追溯；维护约束来自[CONVENTIONS](https://github.com/wvjh3z/proxy-suite-docs/blob/main/CONVENTIONS.md)及ACCEPTANCE，不伪装成用户逐字指令。日期为归档记录日期；未单列的决定日期明确待确认，只影响溯源精度，不改已有授权范围。

| 来源ID／相关F | 日期与负责出处 | 追溯范围 |
| --- | --- | --- |
| REQ-MODE / F09 | 2026-10-28，[PATCHES品牌两模式](https://github.com/wvjh3z/proxy-suite-docs/blob/main/PATCHES.md#品牌两模式约束2026-10-28新增运行时接缝) | 仅智能/全局，底座枚举保留，旧direct归一 |
| REQ-IP / F11 | 2026-10-28，[七源恢复记录](https://github.com/wvjh3z/proxy-suite-docs/blob/main/history/status-through-20261029.md#2026-10-28-品牌首页恢复0893七源ip机制源码与回归完成待设备验收)；本轮显示修复见STATUS | 旧七源与全局证书策略；后续显示修复不是配置完成握手 |
| REQ-THEME / F21 | 2026-10-18，[主题决定](https://github.com/wvjh3z/proxy-suite-docs/blob/main/PATCHES.md#主题默认-theme-system-2026-10-18) | 跟随系统、无偏好时亮色回退、尊重旧选择 |
| REQ-FONT / F21 | 2026-10-22起，[字体核查记录](https://github.com/wvjh3z/proxy-suite-docs/blob/main/history/status-through-20261029.md#2026-10-22-windows换字体后的文字显示异常用户反馈待复现) | 原版字体继承方案；决定具体日期未单列，不把最初故障归因当已证事实 |
| REQ-CRISP / F17 | 2026-10-25，[桌面兼容登记](https://github.com/wvjh3z/proxy-suite-docs/blob/main/PATCHES.md#crisp-040-桌面窗口兼容接缝2026-10-25) | 桌面插件升级与AppImage浏览器边界 |
| REQ-UPDATE / F15/F16 | 2026-10-17恢复前台更新、2026-10-29安装决定；[更新契约](https://github.com/wvjh3z/proxy-suite-docs/blob/main/CONTRACTS.md#免登录自更新) | 检查/下载能力保留，24小时策略、取消摘要校验与上游退出边界 |
| REQ-NET / F02/F04/F06/F14 | [SECURITY](../../SECURITY.md)与[网络契约](https://github.com/wvjh3z/proxy-suite-docs/blob/main/CONTRACTS.md#重试和端点切换)，多次决定日期按各来源；单一统一日期不适用 | Xboard代理继承/证书放行、IP与第三方区别；首启TLS默认见PATCHES的v0.9.2记录 |
| REQ-IDENTITY / F19/F20 | 2026-10-23起，[并存隔离记录](https://github.com/wvjh3z/proxy-suite-docs/blob/main/history/status-through-20261029.md#2026-10-23-原版与双品牌并存审计及隔离实施) | 原版/A/B身份、路径、服务与旧数据归属 |
| REQ-API / F03/F07/F26 | 2026-10-26交付记录及[请求恢复契约](https://github.com/wvjh3z/proxy-suite-docs/blob/main/CONTRACTS.md#重试和端点切换) | 多候选恢复、写操作不重放、业务拒绝不显示HTML |
| REQ-REFRESH / F24 | 源码SubscriptionTriggers记录2026-06-02决定；当前平台接线见ARCHITECTURE | 24小时恢复前台业务刷新；失败耗用窗口是D07现状，不是成功后刷新要求 |
| REQ-IPV6 / F13/F28 | 2026-06-09，[PATCHES接缝点#7](https://github.com/wvjh3z/proxy-suite-docs/blob/main/PATCHES.md) | 首次默认IPv6开启，旧globalUa强制注入已撤销；不覆盖用户后续选择 |
| REQ-SETTINGS / F13/F18/F23 | [当前架构](https://github.com/wvjh3z/proxy-suite-docs/blob/main/ARCHITECTURE.md)及本表生产入口；既有用户要求日期待确认 | 复用新版配置/深层设置能力，不等于每个适配方法已接线 |
| REQ-NOTICE / F25 | 2026-10-27，[公告决定](https://github.com/wvjh3z/proxy-suite-docs/blob/main/history/status-through-20261029.md#2026-10-27-公告入口异步生命周期复核未修复) | 只修销毁后Ref及重复弹窗，迟到公告暂缓 |
| REQ-OTHER / F05/F08/F10/F22、U04/U05 | [STATUS](https://github.com/wvjh3z/proxy-suite-docs/blob/main/STATUS.md)对应修复/暂缓记录及[SECURITY](../../SECURITY.md) | 登录存储/退出、暂停与安全停止、全局分组复用、业务降噪、暂缓恢复协调；不统一编造决定日期 |
