# 当前升级对照基线与功能归属

用途：下一次升级先用本表定位“本项目用了上游哪一层”，再逐项对照新底座。规则唯一维护在[UPGRADING](UPGRADING.md)。本表不是“全平台均已验收”的证明，也不替代PATCHES机器登记。

## 基线身份

核对日期：2026-10-29。本次是文档整理，不改变以下业务源码快照；后续代码变更必须更新本表受影响行和证据引用。

| 对象 | 已核对值 / 来源 | 边界 |
| --- | --- | --- |
| 当前活跃升级分支 | `upgrade/flclash-v0.9.2` | v0.9.1升级分支停止维护，保留历史；不合并main |
| 本次客户端审计提交 | `3b6a5fbba9801eb988aa946786171e1d8b8a719f` | 后续远端变化需重新读取；本表不是永远的latest |
| SDK固定引用 | [release-config.json](../../tool/release-config.json) | 文件是真源；本次读取为`0ae4732249fce585525e548236ec4124d31fb2f0` |
| CI固定Docs | [xboard-ci.yml](../../.github/workflows/xboard-ci.yml)的docs_ref | 本次为`b2650a71b379aba26c3460ba40ed4358e325c112`；工作区新文档未提交时不属于该pin |
| 当前上游FlClash | v0.9.2，`7fd417fb9a9a277c6a9339a8ac87f907df7c25f7` | 真实比较基线，不用客户端HEAD充当上游 |
| 中间上游版本 | v0.9.1，`8d4f9744948751f1273fe871e1d05276fac09b0e` | 用于追溯升级，不再构建维护旧升级分支 |
| 最后旧品牌基线 | v0.8.93品牌代码`ae148e64694ab276c35796f95d77f6bbbe25f0d2` | 用户要求保留的旧品牌行为按此追溯，不等于原版0.8.93，也不复用旧工具链 |
| 内核 | [.gitmodules](../../.gitmodules)和实际gitlink | 本次gitlink为`c5062921054902b25215a6a933e72ccd714c9bfa`；dirty CA不等于指针改变 |
| 工具版本 | [native_toolchain.json](../../tool/native_toolchain.json)、锁文件、workflow | 不在多个手册复制版本表；升级分别验证依赖图与运行行为 |
| 实际工作区 | `/root/dev/workspace/proxy-suite/active/`下的XFlclash、Xboard_sdk、Docs | 版本由Git分支表达；旧版本目录兼容链接已退役，职责见WORKSPACE.md |
| 上游只读参考 | `/root/dev/workspace/proxy-suite/upstream/FlClash-v0.9.2`及同名source.json | 本机便利副本；其他机器以Git对象/官方仓库取得，不能把本机残留当CI输入 |

## 阅读分类

- **复用**：底座执行及语义必须核对，品牌不另写一套替代实现。
- **自有**：保留产品规则，适配确实变化的底层接口；业务名称相同也不能自动用上游覆盖。
- **未使用/间接影响**：没有品牌入口不等于没有共享影响，必须核对provider、迁移、初始化与资源。
- 下表“代码”表示已定位的生产链，“回归”是入口，不表示本轮重新执行。成品和设备证据只查Docs/STATUS当前快照及对应记录。

## 主链路逐项对照

| ID / 归属 | 当前品牌规则与生产入口 | 升级时必须核对 | 回归入口 / 证据边界 |
| --- | --- | --- | --- |
| F01 自有+复用：启动 | [bootstrap](../../lib/bootstrap.dart) → [XboardModule](../../lib/xboard/xboard_module.dart)；品牌就绪、SDK及原生就绪分别处理 | 启动顺序、子进程分流、单实例、未就绪操作门禁；不能仅看界面已出现 | [同步启动](../../test/xboard/bootstrap_sync_phase_test.dart)、[异步启动](../../test/xboard/bootstrap_async_phase_test.dart)；真实启动按平台验 |
| F02 自有：Bootstrap/fallback | [本地加载](../../lib/xboard/services/bootstrap_local_loader.dart)、[远端获取](../../lib/xboard/services/bootstrap_fetcher.dart)、[解密](../../lib/xboard/services/bootstrap_decryptor.dart)；品牌私有配置和fallback按正式入口注入 | 远端/缓存/fallback优先级、超时和旧结果；成品必须验证实际资源，不以源文件存在代替入包 | [fallback成品检查](../../tool/check_fallback_assets.py)、[获取回归](../../test/xboard/services/bootstrap_fetcher_test.dart) |
| F03 自有：API竞速/恢复 | [竞速控制器](../../lib/xboard/services/endpoint_race_controller.dart)、SDK端点恢复；不是每个页面自己轮换URL | API就绪、并发恢复、403/405等异常与业务拒绝区分；写请求不能自动照搬读取重放策略 | [SDK入口](../../lib/xboard/sdk/xboard_service_impl.dart)及Docs/CONTRACTS；具体端点策略须读当前SDK，不据“竞速成功”保证登录成功 |
| F04 自有接线+复用事件：网络变化 | [网络观察器](../../lib/xboard/services/xboard_network_observer.dart)监听有效VPN/暂停与物理网络；前后台触发见XboardModule | 暂停不等于连接有效；物理网络未知不当作断网；竞速、订阅刷新、更新检查仍独立 | [网络观察回归](../../test/xboard/services/xboard_network_observer_test.dart) |
| F05 自有：认证与凭据 | [认证状态](../../lib/xboard/providers/auth_state_provider.dart)、[Token存储](../../lib/xboard/sdk/secure_storage_token_storage.dart)、SDK会话 | 登录落盘失败、会话revision、换号/退出迟到结果、旧凭据恢复与平台存储行为 | [退出](../../test/xboard/providers/logout_test.dart)、[Token恢复](../../test/xboard/sdk/token_storage_recovery_test.dart) |
| F06 自有+复用：加密订阅 | [加密下载](../../lib/xboard/services/encrypted_subscription_service.dart) → [订阅协调](../../lib/xboard/services/xboard_subscription_service.dart) → Profile/内核 | AES与协议校验、当前账号归属、写文件/数据库/内核应用的完成边界；不能把下载成功当节点可用 | [写入协调](../../lib/xboard/storage/profile_mutation_queue.dart)、Docs/ARCHITECTURE订阅章节 |
| F07 自有：订单/套餐/邀请码 | [XboardService](../../lib/xboard/sdk/xboard_service_impl.dart)与页面，协议在SDK | 确认对话框期间换号、服务替换、不可重复写操作、支付浏览器跳转与真实订单状态分离 | [套餐确认](../../test/xboard/pages/plan_confirmation_lifecycle_test.dart)、[订单刷新](../../test/xboard/pages/order_list_force_refresh_test.dart) |
| F08 自有展示+复用执行：连接/断开/暂停 | [连接适配器](../../lib/xboard/shell/adapters/xb_connect_adapter.dart) → [SetupAction](../../lib/providers/actions/setup.dart)；首页在点击时读取认证与同一个操作目标 | setRunning的返回语义、停止失败、未重绘时点击、按需暂停/自动恢复；不自行强制恢复暂停 | [目标时序](../../test/xboard/shell/tabs/xb_connection_target_test.dart)、[暂停](../../test/xboard/shell/tabs/xb_paused_connection_test.dart) |
| F09 自有规则+复用枚举：模式 | [模式政策](../../lib/xboard/config/xb_mode_policy.dart)只开放智能(rule)/全局；底座三态枚举保留，品牌旧direct归一rule | 首页、托盘、快捷键、配置恢复等入口一致；显示不能把实际direct冒称smart | [政策](../../test/xboard/config/xb_mode_policy_test.dart)、[快捷键](../../test/xboard/config/xb_mode_hotkeys_test.dart) |
| F10 自有页面+复用分组：节点/选择 | [节点适配器](../../lib/xboard/shell/adapters/xb_nodes_adapter.dart)使用上游分组状态和changeProxyDebounce；全局保留GLOBAL，不能二次过滤掉 | 模式切换、乐观选择/回滚、分组hidden和真实线路、首页选中投影 | [模式过渡](../../test/xboard/shell/tabs/nodes_mode_transition_test.dart)；另见下方U03 |
| F11 自有：出口IP | [探测器](../../lib/xboard/services/exit_ip_probe.dart)、[provider](../../lib/xboard/providers/exit_ip_provider.dart)及首页卡片；沿旧品牌七源机制，继承当前全局网络/证书策略 | 手动刷新必须呈现检测中，作废旧结果；不换回上游IP缓存门禁 | [探测](../../test/xboard/services/exit_ip_probe_test.dart)、[卡片](../../test/xboard/shell/tabs/xb_ip_card_test.dart)、[生命周期](../../test/xboard/shell/tabs/exit_ip_lifecycle_test.dart) |
| F12 自有调度+复用内核：测速 | 节点适配器调用内核单节点测试，自有池并发；首页延迟另有provider | 当前节点/测试URL、全局组真实叶子、旧批次结果与超时；不能直接套上游整组并发参数 | [节点适配器](../../lib/xboard/shell/adapters/xb_nodes_adapter.dart)及同目录测试；真实网络另验 |
| F13 复用+品牌首次默认：代理/TUN/IPv6 | 复用底座设置与执行；XboardModule首次IPv6设置同时加入generalOverrideKeys | 新版覆盖键和配置迁移语义，不覆盖用户后续选择；系统代理/TUN不能由UI开关显示推断已生效 | [v0.9.2配置迁移](../../test/xboard/config/xb_v092_config_migration_test.dart)；各OS系统状态另验 |
| F14 自有政策+复用宿主：TLS/代理 | [业务HTTP政策](../../lib/xboard/services/xboard_release_dio.dart)用于SDK/Bootstrap/加密订阅/更新下载；[首次TLS默认](../../lib/xboard/config/xb_tls_defaults.dart)只作用品牌初次配置 | Xboard业务放行与全局设置是不同层；用户更改全局证书策略后不把所有请求描述成统一；客服第三方组件保持各自行为 | [HTTPS路由](../../test/xboard/services/xb_update_https_routing_test.dart)、[配置迁移](../../test/xboard/config/xb_v092_config_migration_test.dart)、[安全决定](../../SECURITY.md) |
| F15 自有：更新检查 | [更新服务](../../lib/xboard/services/xb_update_service.dart)等待有效API；冷启动与成功后24小时节流分别维护 | 早期resumed、API切换、手动检查、失败恢复不能误更新时间窗 | [更新测试](../../test/xboard/services/xb_update_service_test.dart) |
| F16 自有：下载与平台交接 | [下载器](../../lib/xboard/services/xb_apk_downloader.dart)、[弹窗](../../lib/xboard/widgets/xb_update_dialog.dart)、[源排序](../../lib/xboard/services/xb_update_sources.dart)；不再比对安装包SHA256 | 取消、重复任务、跨源失败、清理；SDK/后台sha字段不等于客户端校验仍存在 | [实际下载路由](../../test/xboard/services/xb_apk_downloader_routing_test.dart)；平台差异见下表 |
| F17 自有接入+第三方：Crisp | [客服服务](../../lib/xboard/services/crisp_support_service.dart)、[驱动](../../lib/xboard/services/crisp_chat_driver.dart)；AppImage浏览器，其余桌面内嵌；移动端原生插件 | 退出/销毁、账号隔离、URL导航、插件注册/资源/WebView依赖；不能因AppImage外跳把所有平台都外跳 | [会话](../../test/xboard/services/crisp_session_lifecycle_test.dart)、[APK契约](../../tool/check_android_release_contract.py) |
| F18 自有：教程 | [教程详情](../../lib/xboard/pages/tutorial_detail_page.dart)、[阅读器](../../lib/xboard/widgets/tutorial_webview.dart)、[回退阅读器](../../lib/xboard/widgets/tutorial_html_fallback.dart) | Linux按钮/内部教程链接/外链、资源基址和旧回调失效；教程不跟随AppImage客服统一外跳 | [Linux导航](../../test/xboard/widgets/tutorial_linux_navigation_test.dart) |
| F19 自有身份+复用平台：品牌并存 | [身份源](../../tool/identity/brands.json)、[注入](../../tool/brand_identity.dart)、[品牌路径](../../lib/xboard/storage/brand_paths.dart) | 显示名不等于内部ID；原版/A/B的服务、scheme、路径、单实例、资源不能混用 | [品牌CLI](../../tool/test/brand_identity_cli_test.py)、[路径](../../test/xboard/storage/brand_paths_test.dart) |
| F20 自有迁移+复用数据库 | [旧品牌迁移](../../lib/xboard/storage/legacy_brand_migration.dart)、[外挂数据库](../../lib/xboard/data/xboard_database.dart)、[主库访问](../../lib/xboard/storage/profile_database_access.dart) | 只迁可确认归属的凭据；旧共享目录不整体搬运；主库跟随新版，外挂事务/重入独立检查 | [数据库迁移](../../test/xboard/data/xboard_database_migration_test.dart)、[主库访问](../../test/xboard/storage/profile_database_access_test.dart) |
| F21 自有样式+复用主题/字体 | [品牌主题](../../lib/xboard/widgets/xb_theme.dart)、[系统字体](../../lib/common/system_fonts.dart)、[底座主题](../../lib/providers/actions/theme.dart) | 用户字体/主题与亮暗系统切换；局部TextStyle不得丢继承或中文fallback | [字体继承](../../test/xboard/pages/plan_font_inheritance_test.dart)、[亮暗](../../test/xboard/shell/tabs/dark_mode_test.dart) |
| F22 自有：异常上报/符号 | [Sentry启动](../../lib/xboard/services/sentry_bootstrap.dart)、[符号后处理](../../tool/postbuild_sentry_symbols.py) | 预期业务拒绝不生成独立Issue，真实异常保留；符号上传、服务端处理、真实事件解析分开验收 | [上报](../../test/xboard/services/sentry_bootstrap_test.dart)、[失败经验](../build-failures/README.md) |

## 各平台安装/退出边界

| 平台 | 当前实现入口 | 品牌决定 / 升级核对点 |
| --- | --- | --- |
| Android | [APK插件](../../android/app/src/main/kotlin/com/follow/clash/plugins/ApkInstallerPlugin.kt) | 系统安装器接管，启动安装Activity不代表安装完成；包名、原签名、内部版本码和FileProvider须兼容；不构建x86安卓目标 |
| Windows AMD64 | [Inno模板](../../windows/packaging/exe/inno_setup.iss)、[数据删除](../../tool/windows/remove_brand_user_data.ps1) | 原版顺序：准备时卸载品牌Helper并按品牌进程名停止；安装后清遗留代理；卸载确认前也可能停止。已接受不追加服务路径/最终进程复查。保留VC门禁和可选安全数据删除。0.8.93共享安装身份包不等于新版品牌隔离包的无缝覆盖已验 |
| Linux AppImage | [替换](../../lib/xboard/services/xb_appimage_install.dart)、[重启](../../lib/xboard/services/xb_appimage_restart.dart) | 保留自替换，不降级网页；等待旧实例退出，无法exec时恢复并重启旧版，备份保留；不把新版启动后的普通退出当安装失败 |
| Linux DEB/RPM | [打包配置](../../linux/packaging) | 系统包管理/手工安装入口；不得套用AppImage自替换；品牌服务与目录分别核查，RPM仅现行目标支持范围 |
| macOS AMD64/ARM64 | [打包配置](../../macos/packaging)、[更新弹窗](../../lib/xboard/widgets/xb_update_dialog.dart) | 浏览器下载/DMG；Bundle ID、显示名、URL scheme、单架构runtime与符号清单核对；不能把源码检查当Gatekeeper或覆盖安装实测 |
| iOS | 仅作为共享Flutter/移动插件的影响范围 | 当前正式workflow无iOS目标；工具链、签名与设备交付待确认，不承诺可发布iOS包 |

## 平台兼容与支持范围

以下是2026-10-29源码声明，不是覆盖全部系统版本的实测认证；成品和设备结果唯一见Docs/STATUS。构建工具版本取native_toolchain/锁文件，不能把compileSdk、Runner系统或部署目标单独当作用户设备兼容结论。两个品牌共用平台链，但各自身份/签名/资源仍需验收。

| 平台 | 当前发行目标/格式 | 源码门槛与依赖 | 实测与待确认 |
| --- | --- | --- | --- |
| Android | ARM64-v8a、armeabi-v7a APK；不发行x86 | [Gradle](../../android/app/build.gradle.kts)的minSdk继承`flutter.minSdkVersion`；compileSdk由版本目录管理。最终merged manifest和APK ABI/版本码/签名才是安装判据 | 本轮A的#141双APK已确认minSdk24；证据与设备边界见Docs/STATUS；不能用compileSdk37称“必须Android37”，也不能承诺任意32位设备可装 |
| Windows | AMD64 setup.exe | [Inno](../../windows/packaging/exe/inno_setup.iss)声明MinVersion=10.0；[VC策略](../../tool/windows/vc_runtime.json)及原生库共同约束运行条件，教程/客服WebView依赖分别核对 | 不支持Win7的当前安装入口；不能从10.0推定所有Win10发行版都已实测；Windows ARM64未纳入正式矩阵 |
| macOS | AMD64、ARM64 DMG | [Xcode工程](../../macos/Runner.xcodeproj/project.pbxproj)部署目标12.0，Info.plist继承该值；插件/最终Mach-O最低版本仍需成品核验 | macOS12是工程声明，不是全系统实测；当前无本轮Mac实机记录，Gatekeeper/Keychain及插件行为待验 |
| Linux AMD64 | AppImage、DEB、RPM | [DEB依赖](../../linux/packaging/deb/make_config.yaml)：ayatana-appindicator、libsecret、WebKitGTK4.1、libsoup3、libcurl；[RPM](../../linux/packaging/rpm/make_config.yaml)用相应发行版包名。实际ELF/glibc和打包库另验 | 不宣称所有Linux通用；Runner Ubuntu22.04是打包基线，不是所有用户发行版的保证。AppImage客服使用浏览器，仍不能推断整个包无系统依赖 |
| Linux ARM64 | AppImage、DEB；无ARM RPM | 架构专属原生库/ELF及实际包依赖；GitHub原生目标，VDS模拟构建路线退役 | 无本轮原生设备兼容矩阵；不得在x64宿主测试通过后写ARM64设备通过 |
| iOS / Windows ARM64 | 无当前正式发行目标 | iOS插件源码、后台架构枚举或工具候选不等于可发布客户端 | 未承诺支持；恢复目标须独立评估与授权 |

升级或更换工具链时重新核对：Android合并清单和设备ABI、Windows安装器及PE运行库、macOS各架构Mach-O/插件部署目标、LinuxELF解释器/glibc和动态依赖，再做对应设备验证。结果只更新实际版本/发行版范围，不把单台成功扩大成整个平台认证。

## 未使用功能与待核对的间接影响

| ID | 结论与证据 | 升级处理 |
| --- | --- | --- |
| U01 原版主仪表盘 | 品牌主入口是Home/Nodes/Mine，自有首页不采用原版dashboard布局；仍复用底座actions/theme/provider | 上游仪表盘改版不自动改变品牌页面；共用状态仍查F08—F13 |
| U02 上游IP探测展示策略 | 品牌卡片使用F11的自有探测链 | 不自动接入新版上游缓存/门禁；不删除其他原生页面仍使用的能力 |
| U03 隐藏超时节点 | **用户要求不接入；本次发现需单独核实的共享影响。** 当前节点适配器读取proxiesTabStateProvider，底座[proxies状态](../../lib/providers/state/proxies.dart)经filterGroupsState/visibleGroupsState仍可读取hideTimeoutProxies；不能仅凭品牌没有开关就断言不受影响 | 若设置为true可能影响品牌投影，默认未开启不能证明迁移配置也安全。本轮只登记，不改业务；需要有该配置的真实provider回归确认并按用户既有决定处理 |
| U04 备份恢复并发协调 | 用户曾明确暂不处理统一BackupAction恢复协调 | 不新增恢复覆写接缝，不将未处理项写成已解决；底座备份格式/数据库变化仍要检查 |
| U05 严格退出握手/安装期全局门禁 | 用户选择跟随上游，不实施整套严格握手 | 不在“升级维护”名义下重新加入；保留已确认原版行为边界和品牌隔离 |

## 验收和未确认

本表保留源码分类和声明门槛；实际成品矛盾（macOS最低系统、Linux动态依赖、Android版本码）及验证结果唯一见Docs/STATUS和其证据索引。引用的回归存在不代表本轮全部执行。正式包、Sentry逐项确认与设备业务结果唯一以Docs/STATUS当前快照为准。品牌A的一个成品成功不能证明品牌B或其他架构已验收。Windows ARM64、iOS、macOS设备测试能力不由共享源码推定存在。

下一次升级使用这些ID继续对照，不新增一份互相矛盾的“功能全通过”表。用户改变产品规则时，先更新负责该规则的文档和代码，再更新本表相关行；未知共用影响（例如U03）不能被归入“上游会维护所以无需检查”。
