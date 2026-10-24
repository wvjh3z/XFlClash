# Xboard 客户端产品 CHANGELOG

- macOS 库存改在正式打包完成后生成，移除过早的 Xcode 库存阶段；Windows 冷缓存夹具独立设置 longpaths，保留真实失败并补全正负控。

- macOS Sentry 库存校验保留具体失败检查项和安全报告，补齐 #125 元数据结构的双品牌/双架构回归；严格收据规则不放宽，生产触发分支仍待确认。

- macOS 正式分架构打包向 Xcode 显式传递对应架构，避免通用包目标与单架构 Go 内核不一致；保留 Core slice 检查。

- 修复 Windows Flutter 检查子进程启动；rustup 准备与真实 hook 回归统一按 PATH 定位，补齐正式入口的真实工具检查。

- Android 双 ABI 符号准备增加逐库 ELF 清单、区分架构/Build ID 失败并保留安全报告；GitHub 显式校验 ARM32/ARM64 集合。#123 已定位 ARM32 Go 库缺 Build ID，修复外链参数并增加 Flutter 编译前双 ABI 实际链接门禁；修正 macOS 路径别名预期和 Windows 越界负控的清单注入。正式成品仍待复验。

> **本文件是 XFlclash「产品」变更记录**，当前为形态 A「首页 / 节点 / 我的」商业客户端。
> 与上游 `CHANGELOG.md`（FlClash 自身发版）分开维护；同步上游时保留本 fork 的产品记录。
>
> **版本号**：产品版本走自己的 SemVer，与上游 FlClash 版本独立递增。
> 产品关于页读取 `XB_PRODUCT_VERSION` / `XB_BUILD_TAG`；原生 `build-name` 保留底座版本，构建号另行注入。`prepare_flavor` 当前不改写 pubspec 为产品与底座的拼接版本。
> **底座版本**：本独立分支正在升级至 FlClash v0.9.1；规则、发布流程及已验证批次见 [当前文档](https://github.com/wvjh3z/proxy-suite-docs/blob/main/README.md)。Docs 和 SDK 为私有仓库，需要维护者授予访问权限；旧 `.kiro` 仅作历史追溯，不是开发前置条件。
>
> 格式遵循 [Keep a Changelog](https://keepachangelog.com/)：`Added` 新增 / `Changed` 变更 / `Fixed` 修复 / `Synced` FlClash 底座同步。

## [Unreleased]

> 开发中累积（尚无正式 release）；首个真实用户 release 时切走为 `## [x.y.z] — YYYY-MM-DD`。
> 升级目标：**FlClash v0.9.1**（upstream `8d4f974`），正式发行代码与预检已迁移，品牌A Android ARM64构建26已完成本地出包与符号上传，设备及其他平台仍待验收。
> 注：早期按形态 B（v0.1）规划，实际已演进到**形态 A 商业 UI**（唯一 UI）+ v0.2 加密订阅 / Crisp + v0.3 自更新，均累积于此 [Unreleased]。下方历史批次编号用于追溯，发布完成度和设备验证以 [STATUS](https://github.com/wvjh3z/proxy-suite-docs/blob/main/STATUS.md) 为准。

> 当前维护决策：D03 订阅孤儿/重复索引暂缓；D06 校验空值行为跟随上游、暂不修复；D04 续费后账号和节点恢复已获用户实测正常，隔离状态边界与设备行为的差异仍待查。本记录不将这些事项列为已修复。

### Synced
- 固定helper的Rust调用穿过真实hook环境；补助手/PDB与macOS dSYM内容失效恢复、失败报告生命周期及正式CI回归入口，SDK固定引用对齐升级提交；恢复Rust真实解析所需targets，纯Dart工具避免提前启动应用hook。
- 迁移正式打包与Sentry符号链到Native Assets/gomobile，补齐实际Rust产物和helper符号、内核裁剪前后hash绑定、独立固定打包器获取及平台准备顺序；本轮仅本地工具/夹具验证，未发布成品。
- 解决新上游Windows安装事件重名、托盘新目录/DPI变体与图标工具依赖冲突；保留两品牌原安装器、图标和产物命名策略。
- 独立分支合并FlClash v0.9.1，迁移启动/单实例锁、schema20、Profile校验、节点和setRunning连接入口；品牌欢迎、自动更新规则及商业外壳继续保留。
- 自有UI跟随上游material_ui，使用官方兼容桥支持legacy富文本等组件，修复新底座下登录弹窗缺MaterialLocalizations；侧栏和关于页更新底座版本说明。
- 本地Linux品牌A原生业务冒烟与非golden业务回归通过；品牌B独立原生验收按用户决定跳过。平台发行、Native Assets符号采集、真实设备升级仍在进行，未发布新安装包。

### Fixed
- Linux AppImage：依赖扫描跳过 CMake/pkg-config 目录和静态归档等元数据，保留真实共享库缺失错误；补系统 ldd 的品牌包名与旧行为负控。
- Linux 打包夹具按真实 ELF 架构设置目标，兼容 QEMU 下真实 shell 的父进程身份；保留错架构、旧扫描与非 shell 负控。
- Android 原签名验收改用 apksigner 的 PEM 证书字节摘要，兼容不同输出标签，拒绝缺失/损坏或不同证书混入；不改变签名或 APK 内容。
- Windows 符号审计统一使用 build 根目录，允许匹配的 Native Assets/helper 伴随文件并继续拒绝越界。
- 修复升级分支#120前置与制包核验：符号夹具按规范路径比较，Android参数夹具携带真实品牌守卫及公开输入，Linux按完整AppImage的SquashFS偏移只读核验并保留分阶段失败报告；原生/整包CI待复验。
- 正式构建成功后的编号回写跟随源分支，升级分支不再修改main；两个品牌独立更新，有限并发重试保留较大编号和其他提交，标签构建不回写。
- 为两个品牌分离桌面安装标识、数据/缓存/索引、服务及启动/协议注册；Windows主进程/Core/Helper独立命名，安装清理只作用于所属路径，符号清单保留真实二进制匹配。Linux客服WebKit上下文明确按品牌隔离。
- 旧共享数据只迁移已确认品牌的加密登录记录，保留原目录；不再读取或删除无归属旧Token。Android保留包名签名与私有数据，协议使用applicationId；默认代理端口分品牌，不承诺同时接管系统网络。
- 修复Linux RPM品牌启动链接、内核二次裁剪保护及DEB/RPM卸载Helper归属检查；Linux包管理版本使用产品版本和实际构建号，epoch衔接历史版本。正式入口解读最终DEB/RPM/AppImage，比对全部bundle原生文件后才允许符号上传与发布。
- 两品牌四平台将重复的“基本配置／应用程序”入口合并为“通用设置”，实际导航到v0.9.1的GeneralView；保留Android包名、签名、底座versionName和既有ABI编号规则。
- Linux正式制包在受限umask下规范DEB/AppImage临时树权限，AppImage复制bundle内容以兼容目录别名；私密输入权限保持。修复GNU调试伴随文件的ELF note相对对齐，保留损坏边界拒绝。
- 修复固定打包器与Flutter3.47保留版本常量的冲突，保留标准版本参数；两品牌真实CLI参数和公开Flutter bundle正负控纳入正式cold预检。
- 补齐Windows Loader夹具的新内核/助手输入和UTF8读取；Android NDK绑定安装输出并按矩阵目标执行回归，避免旧NDK环境或Linux误入交叉测试。
- 本地桌面打包要求显式`--build-number=N`，缺失或无效输入提前停止，不再静默回退1，不修改远端或Android计数。
- 修复升级后的Android打包：显式开启两品牌resValues，用受摘要校验的项目副本兼容教程插件AGP 9配置，并在DSL收尾前统一Java 17以保留Android系统类路径。
- 修复Flutter 3.47的AOT成品校验路径，并为Android Rust桥接库生成Build ID；补齐真实AGP、三ABI NDK和发布失败保护回归。品牌A构建26原签名/fallback/AOT核验通过，7份必需符号已获Sentry服务端确认。
- 补齐Go符号的外层文件依赖与内容校验，修复增量恢复；相同Rust符号捕获保留时间戳。Windows坏交接清单统一生成失败报告，本机桌面统一python3，CI入口改用命令语义回归。
- 两品牌共用的品牌主题保留 FlClash/Material 平台字体继承；首页速度、套餐价格与 Emoji 混排补齐默认文字样式，按钮/弹窗沿完整主题派生。移动速度在窄屏放大文字时完整缩放显示，不新增字体资源或底座接缝；用户 Windows 换字体后的缺字反馈仍待同机验收。
- 修复干净Runner缺Gradle wrapper导致Android品牌预检失败，以及macOS旧Bash空数组展开错误；固定Gradle工具校验与冷缓存回归。Sentry收尾增加准确阶段诊断、有限处理等待和逐项服务端符号确认，保持真实失败阻断发布。
- 两品牌桌面在读取/迁移数据库前获取单实例锁，保留客服子进程豁免；主库后台连接加入有限等待，订阅仅对同一 Profile 的安全写入做有限重试，重试前核对会话，不重复下载、写文件或激活。保留现有数据库目录、schema 与备份方式，设备验收待新包。
- 两品牌Android启动器名称与应用内名称统一使用完整YAML解析结果，支持中文、Unicode转义和单引号；最近任务描述改为品牌名。原生身份生成物在构建前校验来源与完整性，CI/本机入口共用，设备显示待新包验收。
- 修复订单列表、套餐列表和续费页重试失败时的未处理异步异常；保留页面错误与重试入口，下拉等待请求结束，旧请求晚到不覆盖新请求状态。支付/登出共享完整清理Future，并发池补齐同步抛错及立即完成边界；两个品牌共用，403处理策略保持原样。
- 修复Windows WebView前置回归默认按CP1252读取UTF-8工作流导致的构建阻断；夹具显式声明文本编码并增加旧错误负控。
- AppImage品牌关键词纳入构建期注入，移除Windows发布者测试占位；Emoji对齐迁入Xboard组件，恢复两份上游文件并退役对应静态接缝。
- 两品牌Windows构建定向修复教程WebView插件在进程退出时静态析构WinRT图形资源导致的崩溃；只改构建副本，保留每视图释放和原退出流程，增加C++子进程正负控及源文件漂移阻断。真实Windows新包退出仍待设备验收。
- CI与本机桌面打包共用公开构建上下文、分发器参数和严格产物清单，阻止缺包/重包/空包/错批次上传；保留各自编号来源。固定静态检查工具与appdmg，增加工具版本报告、构建阶段超时和仅按清单上传，草稿聚合发布仍待后续独立调整。
- 修复发布流程将新增测试文件误判为命令错误：改为必要参数/测试集合校验并验证失败传播；纯结构检查各平台执行，完整共享回归在矩阵前运行且拒绝空跑/跳过，本机与CI复用同一离线入口。
- 修复Windows构建前品牌测试对CRLF换行的误判：工程配置解析仅在内存中归一换行，增加真实Git checkout的LF/CRLF正控、旧正则负控和配置缺失/错名断言，不改产品或Git换行策略。
- 两品牌Windows安装器标题、应用列表版本及安装器版本资源改为品牌产品版本和本次实际构建号，停止展示pubspec中的上游日期编号；CI与本机桌面入口显式传号，参数缺失/非法或漏注入时阻断打包。
- 整理两品牌Windows安装器必要组件页：顶部显示运行环境说明，正文仅显示一次检查/安装状态，中英文同步，消除重复提示。
- 修复两品牌Windows安装时运行库子进程继承无效工作目录的问题；安装器与检查脚本分别指定真实目录，记录注册/DLL版本、跳过或安装决策、执行阶段及系统错误码，并区分准备、检查、子进程启动失败。新增真实无害子进程回归，最低版本和离线安装策略不变。
- 修复Windows安装器将Pascal运行时函数误用于ISPP路径计算的问题；两品牌正式编译前增加真实maker渲染与ISCC脚本预检，覆盖旧路径错误、准备失败和Pascal错误负控，并保留安全诊断。预检不编译客户端、不输出或执行安装包。
- CI超时/清理回归分离可控时钟与真实进程验证：确认父进程、后代就绪后触发清理，并用连接关闭及存活负控核验，消除Windows上250毫秒启动速度假设；生产依赖重试的300/720秒预算保持不变。
- 修复构建工具的跨平台进程清理：macOS已退出进程组的EPERM需经回收与存活核验后处理，真实清理失败继续阻断；Windows worker独立传递启动状态，避免缺失命令被误记为普通退出。依赖重试与Sentry扫描共用有界清理，补齐安全诊断和离线回归，未重新构建客户端。
- 两品牌Windows安装器内置微软最新x64 VC++运行库，已有运行库达到独立最低要求时跳过；缺失/过旧时离线安装，补齐文件复核、中文提示、失败/重启阻断及工具链与载荷校验。源码和离线回归已完成，Windows成品与真实安装验收待后续构建。
- CI的显式Flutter/Dart依赖获取使用有上限的网络重试：最多3次、单次5分钟、每条命令总预算12分钟；版本/认证/证书/磁盘错误及时失败，取消和超时清理本次进程树，保留安全诊断；不重试代码生成、编译或打包。
- SDK 1.22.0的已分类业务拒绝（登录/注册/验证码/优惠券/订单规则/限流/正常认证过期）保留info日志和Sentry面包屑，避免独立Issue；未知4xx、5xx、响应损坏、真实异常继续原上报，业务提示、结果与会话行为不变。
- Windows/macOS/Linux共用桌面导航栏的品牌Logo读取构建期注入的品牌原图，移除固定盾牌占位；保留原色与透明区域，两品牌沿用同一资源注入链。
- macOS登录存储改用传统钥匙串；各平台补齐安全存储读写删除核验、加密回退、品牌隔离和持久化退出记录，避免保存失败、旧凭据复活与迟到写入污染新会话；生产存储配置无效不再退到SDK明文存储，真实设备验收待后续包验证。
- macOS 主应用显式显示名与 Bundle 名统一跟随品牌 PRODUCT_NAME，清理三种构建配置的 FlClash 显示名遗留；补齐两品牌中文名称切换与幂等回归。
- 品牌图标资源保留Git提交原始字节，避免Windows换行转换改变品牌B单色SVG、触发系统图标摘要校验失败；补齐两品牌真实Git检出的正负控。
- Linux CI两种架构统一Python3.12并核对实际解释器；打包工具源码导出保留合法内部相对链接，拒绝路径与链接逃逸，避免旧版tarfile误判阻断amd64出包。
- Linux AppImage适配固定旧工具的ARM架构参数，工具按官方资产和SHA256校验；打包前检查真实ELF架构，补齐真实工具正负控和SquashFS载荷核验，保留失败审计报告。
- Linux打包前置回归使用独立Git提交夹具，兼容CI子模块浅克隆及无全局Git身份，保留固定版本拒绝校验。
- Android CI通过独立参数传递双ABI，避免逗号二次解析生成非法Flutter选项；Linux使用锁定工具副本统一去重AppImage依赖并校验内容冲突、传播实际架构。macOS符号工具补齐进程生命周期诊断与独立回归，两种Runner统一测试Python；真实修复出包待后续验证。
- 退出登录的加载遮罩由本次独立路由管理，游客布局重建、其他弹窗覆盖或页面释放后仍能正确收尾，避免本地清理完成后持续转圈；共用品牌主题内容，保留账号清理和停止归属VPN的顺序。
- GitHub 打包恢复单次手动触发：移除仅为列表标题显示自动编号而增加的准备/二次分派流程，兼容省略或留空的可选构建号；保留自动取号、手动指定、固定源码/SDK及符号链。草稿上传成功后同步标题和说明中的编号，拒绝覆盖已公开版本。
- 清理打包配置冗余：删除 Windows maker 未读取的两个输入键，将标准品牌注入前的应用名/显示名默认值恢复上游；保留安装身份、发布者、快捷方式、链接策略和有效 AppImage 关键词。
- Xboard业务的SDK API、Bootstrap、加密订阅、端点探测与安装包下载继承宿主既有全局代理，原FlClash网络实现保持原样；业务通道关闭持久连接，避免后续HTTPS沿用旧代理隧道。SDK修正DIRECT及SOCKS未装配的日志误报，补齐显式SOCKS HTTPS证书放行；浏览器与应用内更新共用稳定地区排序，打开失败继续换源并保留重试提示。
- 教程资源沿业务请求统一忽略证书验证：Android/macOS接入服务端信任回调，Windows独立WebView2环境传证书放行参数；第三方客服、Sentry和节点协议保持现状。
- macOS 受控符号验收兼容 Swift 空参数函数的 name-only 表示，继续严格核对模块身份、地址、文件和源码行，避免已正确解析的事件因缺少显示括号被误判失败。
- CI 拉取私有 SDK 时使用临时请求头并禁用系统凭据助手，客户端 checkout 不再保留 Git 认证配置，避免构建阶段依赖交互式凭据授权；Mac 出包先完成有界 Swift 包解析。
- macOS 静态 Swift 包的目标行覆盖证据与宿主 dSYM 分别记录，受控解析按目标 CPU 架构选择模块，保留无法验证的覆盖限制。
- macOS SwiftPM 区分经严格来源验证的空链接辅助目标和实际源码，避免把预编译包装误判为必须提供源码 dSYM；预编译运行模块与静态供应商代码的覆盖限制分别校验，同名时也不能互相替代。
- macOS 符号按实际架构分别匹配，支持独立 thin dSYM；缺失时从 UUID 和执行代码均匹配的构建源镜像生成，保留全模块安全诊断。Rust 准备与独立审核逐架构检查，失败重试清除旧完成状态，缺必需符号继续阻断上传。
- Windows 顶层 CMake 同时初始化 C/C++，修复纯 C SQLite 目标生成 PDB 清单时的构建失败；保留必需符号检查。
- Linux 符号准备覆盖无后缀的 Crashpad 助手和全部运行副本，安装时统一保护未剥离源文件；macOS 按实际 Pods/SPM 链接图记录动态模块、静态宿主与预编译边界，并将库存与最终应用绑定，缺失或不匹配时阻断符号流程。
- Android 自动符号流程补齐实际入包的两份 Sentry prefab 调试库，按 APK 的 ABI、Build ID 和代码段匹配后提取独立调试文件；缺失或不匹配时阻断正式符号上传，调试库不加入安装包。
- Sentry 符号重复上传时，已在服务器处理的文件不再被 CLI 2.58.4 误报缺失；继续校验完整本地符号、精确 ID 和服务端完成状态，上传失败或未完成仍阻断正式出包。
- 四平台正式打包及本机Android统一完成Sentry符号生成、匹配和上传处理；缺凭据或必需符号失败。本机保留可补传归档，上传或配置恢复失败不覆盖正式APK、不递增构建号。
- macOS补齐Dart split-debug-info、runner/源码Pod与Rust dSYM，CI固定Flutter3.44.2以保证AOT/符号标识一致并移除pub get后台SPM预取，Go在分发strip前导出独立行符号；Windows补齐Rust PDB和最终插件库存检查。Android只在实际入包时要求Rust，不再被不存在的安卓库阻断。
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
- 两品牌系统图标：Windows/Linux 托盘使用品牌原色图与暖橙、青绿、蓝三态圆点；macOS 使用品牌单色 template；Android 通知小图标、快捷磁贴和文件选择器根目录使用品牌单色轮廓，沿用现有状态逻辑。
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
- 默认主题改为跟随系统：系统亮色时显示亮色、暗色时显示暗色；两品牌移动与桌面端共用，保留已有配置中的手动主题选择。
- Windows、macOS、Linux 与 Android 共用恢复前台时的更新检查：首次允许，后续成功检查间隔24小时，失败允许下次恢复重试；与账号资料刷新、移动端计时器独立，保留冷启动和手动检查规则。
- Sentry 客户端精确升级至 9.30.1，保持 CLI 2.58.4、原始诊断采集范围、启动早期捕获和上报开关重启生效策略；Android JNI 生命周期修复及桌面原生依赖更新随包采用，原生平台新包与符号验收分别进行。
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
