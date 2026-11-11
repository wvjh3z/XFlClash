# XFlclash 构建失败经验（唯一维护入口）

<a id="构建失败经验索引"></a>

本目录随客户端代码和分支维护，适用于两个品牌、GitHub Actions、Jenkins及指定构建机。排障及修复交付必须读取和更新，见客户端[AGENTS](../../AGENTS.md)。main当前底座及后续版本的失败事件在此维护；历史记录保留在 [v0.8.93 复盘](v0.8.93.md) 和 [v0.9.1 Jenkins/Actions 复盘](v0.9.1.md)，不复制其正文。当前操作步骤以 [DEVELOPMENT](https://github.com/wvjh3z/proxy-suite-docs/blob/main/DEVELOPMENT.md) 为准，归档硬性要求见 [CONVENTIONS](https://github.com/wvjh3z/proxy-suite-docs/blob/main/CONVENTIONS.md#构建失败后的修复经验必须归档硬性约定)。

记录区分“失败已确认”“修复待实施”“受控验证通过”“正式构建复验通过”，不能由后续不相关改动或一次本机成功替代。每次修复更新原事件，记录实际提交/工作区状态、正负控、正式入口及未验证边界，不另建重复事件。


## 按底座版本查阅

| 底座版本 | 经验记录 | 适用范围 |
| --- | --- | --- |
| v0.8.93 | [完整历史复盘](v0.8.93.md) | 历史事件及跨平台教训；不是当前工具链指南 |
| v0.9.1 | [Jenkins与Actions复盘](v0.9.1.md) | 原生资产、平台打包、符号和远端构建经验 |
| v0.9.2 | [#140及后续修复](#actions-140v092首次全平台构建) | 已合入main；已实施与待复验分别记录 |
| v0.9.3 | [升级候选验证](#v093升级候选验证2026-11-08) | 源码交付状态见Docs/STATUS；各批受控/原生夹具与设备验收分开，旧“未提交”描述保留当时语境 |

跨版本排障先按错误阶段搜索三个文件，再核对该事件源码、版本、架构和验证边界；不要把旧配置直接应用到新底座。新版本增加版本项，每个事故在对应记录维护，不丢弃旧经验、不复制同一事实到两处。

## 事件索引

| 事件 | 品牌 / 目标 | 首个失败阶段 | 当前状态 |
| --- | --- | --- | --- |
| [Actions #173/#174 Linux APT](#actions-173174-linux-apt依赖失败2026-11-12) | A/build54、B/build42；Linux AMD64/ARM64 | Ubuntu归档DNS失败，update软失败后继续install，15分钟超时 | 严格索引/有界下载备源/离线安装已接线；定向66项通过，完整共享门禁本机缺CMake，正式CI待验 |
| [Linux build54节点断连](#linux-build54节点断连2026-11-11) | A Android ARM64 / Jenkins #6 | 首个远端sh前Remoting/WebSocket ClosedChannelException | 无工作区/无APK，节点现已恢复在线；底层原因未知，待授权重试 |
| [Linux build53调度准备](#linux-build53调度准备2026-11-11) | A Android ARM64 / Linux节点 | 维护机缺Paramiko；SSH信任文件相对路径未解析 | 改用现有OpenSSH并按运维仓库根解析原信任文件，未绕过验证；正式构建结果另记 |
| [套餐右上价格基线](#套餐右上价格基线回归2026-11-11) | 两品牌共享UI；Windows测试宿主 | 测试在布局/绘制阶段之外调用getDistanceToBaseline触发Flutter断言 | 改用dry baseline查询，保留几何断言；16项及两文件分析通过 |
| [浅色表面与测速入口](#浅色表面与测速入口回归2026-11-11) | 两品牌共享UI；Windows隔离宿主 | 残留导入、夹具漏等菜单动画、点击已移出视口的标签 | 修正导入及测试交互前提，45项通过；既有弃用info、golden/设备边界保留 |
| [套餐列表四行布局](#套餐列表四行布局回归2026-11-11) | 两品牌共享UI；Windows测试宿主 | 夹具把第4个逻辑段误当第4个显示行 | 改为实际可见行盒断言，16项通过；golden/设备待验 |
| [Windows ARM64恢复](#windows-arm64-恢复准备2026-11-11) | A/B共享源码；A原生ARM构建 | #161–#167：请求/前置、路径、bootstrap、架构及教程插件STL1011 | 逐次索引及红绿证据见专项；#167窄作用域兼容已补，正式ARM复验待完成 |
| [品牌分组菜单回归](#品牌分组菜单回归2026-11-11) | A/B共享UI，Windows隔离宿主 | 重复激活错误pop内容页；测试准备/旧断言失败 | 稳定Page身份保护；17文件分两批186项通过，golden/设备待验 |
| [VC诊断编译与复核](#vc诊断编译与来源分类2026-11-11) | A/B Windows共同安装器 | Inno预处理换行、PS_MINIVCL接口；协议丢失来源误判 | 原生四组中英/剪贴板正负控通过；完整maker/正式失败页/真实redist恢复待验 |
| [#150 SDK访问](#actions-150-sdk认证2026-11-10) | B 全六目标 | 私有SDK clone退出128 | 诊断证实原Secret401；授权同步后#151越过检出，不把128直接当过期 |
| [#151 Android协议夹具](#actions-151-android协议夹具2026-11-10) | B/build37 Android；五桌面成功 | 引用旧CoreMethod加载失败，无该批APK | 新接口/响应/wireName修正受控通过；后续B39/40成功归属见STATUS，设备另验 |
| [Windows build45制包/采集](#windows-build45原生制包与普通用户采集) | A Windows AMD64 | NuGet/JDK、ATL、安装前缀，随后普通用户Sentry数据库 | 分阶段保留失败，build46/48限定原生结果见候选证据，不外推其他目标 |
| [GET采样/浏览器回归](https://github.com/wvjh3z/proxy-suite-docs/blob/main/evidence/update-get-probe-20261110/review-fix.json) | A/B共享业务 | Dio提前缓冲、取消异常、字号溢出 | 74/74受控通过；B40含修复，真实浏览器/设备仍待验 |
| [v0.9.3候选验证](#v093升级候选验证2026-11-08) | A/B共用源码；Linux与Windows夹具 | 接口/测试宿主、golden环境及测试传输准备 | golden经论证、原型/配色修复和分批批准后最终55/55；原生缺口另记 |
| [偏好提交失败候选夹带](#偏好提交失败候选夹带2026-11-08) | A/B Windows/Linux适配器 | 失败候选被后续写入夹带 | 旧25例20失败→188通过；后续Windows适配器40/40及6负控已有，后续门面/完整原生恢复边界见STATUS G05 |
| [Jenkins本地工作区快照准备](#jenkins本地工作区快照准备2026-11-08) | Linux / 最新未提交工作区回归 | 源码一致性守卫发现准备步骤改写build_config | 核实为名称补引号后恢复快照原字节；89例通过，3503项前后一致 |
| [Jenkins测试采集器时区缺失](#jenkins测试采集器时区缺失2026-11-08) | Linux / 偏好存储实文件验收 | 测试前ZoneInfoNotFoundError | 采集器使用明确北京时间UTC+8；测试随后14/14通过，非业务修复 |
| [Jenkins Gradle计时无报告](#jenkins-gradle计时无报告2026-11-08) | 两品牌共用驱动 / Android；夹具为离线Gradle9.8.0 | init设置profile后任务成功，但报告缺失 | 改用任务完成事件；真实成功/失败夹具通过，完整新包未验 |
| [Jenkins Android #2内存压力](#jenkins-android-2内存压力2026-11-08) | A / Android ARM64 / 产品build44 | flutter-apk：Gradle/Kotlin持续内存回收 | #2中止；降低节点Android预算后#3正式入口及APK/原证书/Sentry7/7通过，设备待验 |
| [Actions #140](#actions-140v092首次全平台构建) | A / Windows AMD64 | Windows runtime prerequisite rules：identity竞态夹具 | 首修3b6a5fbb后#141仍失败；9c136383补修，#143正式新批次通过（历史失败保留） |
| [Actions #140](#actions-140v092首次全平台构建) | A / Linux AMD64 | Package：Native Assets Go依赖获取 | 3b6a5fbb修复后#143全六目标通过；#140原始变化文件/写入者仍未查明 |
| [Actions #141](#141windows夹具文件占用与macos符号传输失败) | A / Windows、macOS AMD64 | 夹具占用、符号传输及证据上传网络失败 | 9c136383修复，#143源码a3152f5b正式复验通过；非设备业务验收 |

**当前结论**：以下“未提交/待修/待复验”是各历史阶段当时状态，不是当前main状态。首轮修复提交3b6a5fbb，#141暴露剩余问题，9c136383补修，#143（a3152f5b）全六目标成功；已合入main。正式证据见[run143](https://github.com/wvjh3z/proxy-suite-docs/blob/main/evidence/run143/README.md)。不能由新批次成功反推#140具体文件变化原因已经找到。后续按新失败证据另评估，不覆盖历史。

## v0.9.3升级候选验证（2026-11-08）

### Actions #173/#174 Linux APT依赖失败（2026-11-12）

两批均固定源码07fd0f45261aeb5d68f9de7e223463aee06835c9。A [#173](https://github.com/wvjh3z/XFlClash/actions/runs/43050035131)为build54，B [#174](https://github.com/wvjh3z/XFlClash/actions/runs/43050085572)为build42；两品牌均仅Linux AMD64/ARM64失败，Android、Windows双架构及macOS双架构五任务成功，bump跳过。四份失败日志均指向Install Linux package deps：AMD64的azure.archive.ubuntu.com、ARM64的ports.ubuntu.com暂时无法解析。apt-get update警告后返回并沿旧索引继续install，随后步骤15分钟超时。源码中该APT步骤与上次成功#172相同；底层Runner DNS故障原因未知，不认定为UI/SDK编译回归，也不把pub缓存miss当失败。

复现：以冻结workflow的原Linux步骤运行实际Bash、仅替换sudo/apt-get为受控命令；update模拟日志中的“failed indexes + exit0”，旧步骤确实到达install。修复限定自有CI准备工具：amd64仍Ubuntu22.04/jammy、arm64仍Ubuntu24.04/noble，使用临时架构限定.sources和新索引目录，Canonical HTTPS主源/对应Azure备源；Signed-By保留Ubuntu原keyring，不改系统sources或resolver。update强制Error-Mode=any，并拒绝兼容情况下的exit0失败索引警告；下载完成后--no-download安装，安装阶段不重试。签名/证书/完整性/认证/包缺失/配置/锁错误优先失败，只有索引/下载网络错误或依赖阶段超时允许一次备源恢复。总预算840秒，update120/download240/install240秒单阶段上限，共享总预算，保留workflow15分钟外限。

报告先写RUNNER_TEMP/linux-package-deps.json（root产生但0644供runner读取），always再复制到build/dependency-retries/linux-apt.json；首传/上传重试均沿既有目录归档，避免改artifact根布局或被flutter clean丢掉。保留xvfb/dbus、WebKit4.1/libsoup3、curl/secret/jsoncpp、AppImage等依赖，FUSE按发行版明确选libfuse2或libfuse2t64，rpm仅amd64，取消用任意安装失败触发换包名的旧`||`路径。

经验复核：v0.8.93 E2及v0.9.2 #140/#141要求按工具/阶段分类、有界重试、永久错误优先、取消清理和证据首传/重试一致；本次分别落入APT下载层和always归档，没有整套编译重试、关闭签名、升级amd64 Runner或延长步骤超时。旧workflow接线负控1项预期失败；最新APT/依赖契约26项、发行workflow契约40项均通过，actionlint/ShellCheck通过；四组真实APT只读indextargets解析与16个公开InRelease HTTPS读取通过（读取不替代APT GPG验签）。完整tool/check_release_workflow.py本机退出2：缺cmake，未恢复退役工具链，未以替身冒充完整门禁成功；正式新CI安装/制包待用户另行运行。原始四job日志、复现、正负控及缺项见Docs/evidence/actions-173-174-20261112。

### Linux build55状态回收停滞（2026-11-11）

Jenkins Android ARM64 #8在Starting flutter-apk后停止编译进度输出，反复“节点offline、等待5分钟”，超过30分钟仍building，但节点API已online。用户要求核验后通过原严格SSH检查发现release全部步骤退出0、verification completed、Sentry7/7及out APK已存在，durable-db81e208/jenkins-result.txt为0；flutter-apk实际472.9秒，不是持续编译半小时。

处理限于只读取证和直接取回APK/符号，未重启服务、重发构建或篡改Jenkins终态。APK67552482字节/versionCode1000055/原签名/AOT/fallback/仅ARM64与12模块CRC核验通过，符号107887074字节已取回。根因仅定位到节点通信/编排收尾，不宣称底层已修复。记录见Docs/evidence/android-arm64-a55-20261111/direct-result.json；最终Jenkins状态需另补，不能用未来编排失败覆盖已核验的产物事实。

用户后续主动停止等待器，Shell.NotFoundError为取消回执，不是新增构建失败；不据此重启等待或重发。已另获明确授权发布build55到HTTPS8081，页面与全包回读通过，发布与编排终态分开记录。

### 胶囊按压像素夹具帧时序（2026-11-11）

build54后胶囊/列表简价候选10文件分析通过。`test-20261111-222210`前48项通过，新像素用例却在“左侧必须有反馈”断言得到0：单次pump到达手势确认时启动ink ticker，该帧仍是动画起点，尚未画出按压反馈。不是右侧隔离失效，也不能通过删除左侧正控来通过。补手势后的首帧和后续200ms绘制，保留左右两个真实像素差断言；`test-20261111-222433`两文件18项全通过，实际左侧变化>0、右侧=0，刷新倒计时/忙态/共享手势及测速冷却同时通过。最终夹具分析无问题。原失败报告及后续正控分别保留于Docs/evidence/capsule-price-refinement-20261111/results.json，未构建新包或声明设备通过。

### Linux build54节点断连（2026-11-11）

用户授权同输入重试后的#7已SUCCESS（810579ms），build54原签名/仅ARM64/AOT/fallback/Sentry7/7通过，APK与匹配符号已取回，本机ZIP CRC及12个AArch64模块复验通过。没有改变源码、驱动、服务或网络；本次成功不证明#6底层断连原因已修复，原失败记录保留。正式正控摘要见Docs/evidence/android-arm64-a54-20261111/success.json，设备未验。

Jenkins android-arm64 #6（A/build54，冻结源04ca3d59d1f6）181149ms后FAILURE，无artifact。Frozen source and toolchain首个sh未输出实际命令，Remoting/WebSocket ClosedChannelException及RequestAbortedException；post always也因DumbSlave offline失败。没有执行APK编译，不归因于本轮Flutter改动或build53已修的编号初始化。

用户要求核验后，API返回同一Linux节点online、temporaryOffline=false、两执行器空闲；原SSH严格信任通道可用，目标android-arm64-6工作区不存在，无checkout/release-batch/reports/APK。仅确认断连机制，不把当前在线当作底层原因已修复；没有重启服务、调整网络或自动重发。待用户确认同冻结输入/build54重试；完整私密日志与公开摘要归Docs/evidence/android-arm64-a54-20261111/failure.json，正式重试结果需另补。

### 应用内模式滑块分析失败（2026-11-11）

本轮Android胶囊尺寸、套餐底行价格及模式动画的首次分析`analyze-20261111-211543`退出1，xb_mode_segment.dart新增AnimatedPositionedDirectional后漏闭合构造器，Row被解析为其位置参数，报extra_positional_arguments_could_be_named/expected_token。补齐括号后`analyze-20261111-211725`八文件无问题，正式受控入口`test-20261111-211837`六文件48项通过，包括实际动画中间位移、快速反向与减少动画，不以只检查duration字段替代动画行为。未启动应用构建；原红绿日志/源摘要见Docs/evidence/ui-polish-20261111/results.json。

### Linux build53调度准备（2026-11-11）

正式复验已完成：Jenkins Android ARM64 #5 SUCCESS，554681ms；counter-seed记录起点52/请求53，原签名、仅ARM64、AOT/fallback和Sentry7/7通过，APK与匹配符号已取回。此前#4前置失败与预期红控不改写，具体材料见Docs/evidence/android-arm64-a53-20261111/success.json。产物采集脚本曾将Sentry的字符串build_number直接与整数53比较而断言，规范化比较后回读通过；属采集类型假设错误，不是APK/Sentry失败。未验设备、不做公开发布结论。

用户随后授权修复并重试。Jenkins v2适配器新增仅新workspace的requested-1初始化，已有计数不降低、已绑定批次缺计数及符号链接拒绝；正式CLI仍执行原门控和成功回写。4项新回归先红，随后全7项通过；真实CLI的受控正控确认53越过编号门控并写入53输入，无原生调用。节点空闲时原子部署并校验，已派发#5同源码/build53；正式结果待回报。补丁/部署摘要见Docs/evidence/android-arm64-a53-20261111，#4失败不改写。

正式Jenkins Android ARM64 #4随后FAILURE：代码生成完成后，本地release门控拒绝显式53。远端新workspace的Git下一编号53被首次迁移成本地起点53，而本地release要求严格大于current；实际无build-inputs/verification，不存在该workspace的成功build53。维护机用临时公开夹具调用真实main并mock工具探测复现相同拒绝，无原生调用。需修正Jenkins显式编号初始化适配，保留已有成功计数不可倒退和重复编号门控；当前未修复/重试，不能用改号54替代用户明确要求53。原始273448ms批次日志和阶段timings已归档至本批archive，见Docs/evidence/android-arm64-a53-20261111/result.json。

本轮首次只读节点检查因维护机未安装Paramiko失败，尚未派发应用构建；改用已有OpenSSH与受限记录驱动的SSH_ASKPASS，不安装额外库、不把密码写入命令行或项目。随后StrictHostKeyChecking拒绝连接，因为运维记录的known_hosts_file为相对运维仓库根的路径，错误地从客户端cwd解析后找不到。按记录所属运维仓库根解析成绝对路径，继续使用原known_hosts并保持严格校验，连接及四份v2驱动摘要正控通过；没有接受新主机密钥、修改known_hosts或绕过信任检查。

源码bundle随后传入独立目录并校验通过，用户明确要求与GitHub同源码build53同号，Jenkins Android ARM64 #4才正式派发。上述环境失败不得记成Gradle/编译失败或出包结论；原受限SSH诊断位于任务目录，公开范围与结果见Docs/evidence/android-arm64-a53-20261111。构建完成/失败后按原阶段继续补充，不改写这两个准备失败。

### 浅色表面与测速入口回归（2026-11-11）

后续用户最终采用标题栏双图标胶囊、测速中仅转圈。`analyze-20261111-200129`因两处prefer_const_constructors退出1（一处由背景改透明产生，一处是本次触及的旧恢复夹具）；补const后`analyze-20261111-200448`十文件无问题。`test-20261111-200324`八文件55项通过，包含刷新按钮/手势/防重/冷却、账号切换和胶囊尺寸。没有关闭info门槛消红，原始退出码与最终十文件摘要见Docs/evidence/surface-delay-20261111/capsule.json。下文为此前分组栏版本的历史失败与修复。

本轮为main上未提交候选，主题浅色层级与Android工具栏测速入口重构；Windows隔离测试目录复用已结束的plan-list批次，不是出包。首轮`analyze-20261111-192843`退出1：节点控件移除测速状态后残留xb_feedback导入，同时出现原有MaterialUiCompatibilityBridge弃用info。删除无用导入；后续7文件分析使用`--no-fatal-infos`退出0，info仍完整保留，未以忽略warning宣称无问题。

`test-20261111-192950`退出1：新增工具栏用例在菜单tap后立即读取目标标签，未等待Prism返回动画。按同文件原有交互用例等待pumpAndSettle，再检查目标分组，随后29项通过。`test-20261111-193604`退出1：工具栏预留44px入口后，模式切换夹具仍假设此前分组文本中心在视口内，tap命中点为负X，业务选择保持GLOBAL。先ensureVisible并等待滚动稳定再tap；保留模式切换/分组归属断言，并增加Android圆形/桌面文字入口接线断言，随后16项通过。不扩大页面宽度、不关闭warnIfMissed、不删行为断言消红。

原红日志是失败前提证据，修正后的相同入口为正控；没有把夹具问题当成生产测速失败或触发应用构建。受测8份源码摘要、全部命令/退出码与21份日志索引保存在Docs的[evidence/surface-delay-20261111/results.json](https://github.com/wvjh3z/proxy-suite-docs/blob/main/evidence/surface-delay-20261111/results.json)。真实倒计时到期、golden、Android/桌面设备视觉和新包仍待验。

### 套餐右上价格基线回归（2026-11-11）

用户在已交付三行居中布局后要求右上价格与名称平齐。生产布局采用Row的alphabetic baseline；新增基线几何断言首轮`test-20261111-200838`退出1，因为直接调用RenderBox.getDistanceToBaseline时不处于其父级layout/paint阶段，触发Flutter debug断言，并非生产布局溢出。改用同约束下的getDryBaseline读取；仍验证全局文字基线相同、名称/价格横向隔离、介绍位于标题行下方且最多三行，没有把基线断言删掉或改成仅检查配置。

`test-20261111-201041`两品牌四平台配置×360/1000宽度×1.0/1.4字号的布局和字体16项通过；`analyze-20261111-201115`两文件无问题，pubspec/lock身份保留，源摘要与本地一致。原失败日志为负控证据，修正后的同一几何断言为正控；因fail-fast取消的字体文件不记为字体缺陷。红绿记录见Docs/evidence/plan-list-layout-20261111/top-right.json，原四行/三行居中证据不改写。未构建、部署、更新golden或做设备验收。

### 套餐列表四行布局回归（2026-11-11）

新增布局测试首轮在WIN11-BUILD失败：断言“第4个逻辑段必须可见”，但360宽度/大字号下前几个段落已自动换行，正确的四个显示行预算可能在第4段前耗尽。属于测试假设错误，不能通过把生产限制扩成更多行来消红。改按RenderParagraph实际可见行盒计数恰好4行，并保留第五段/长段尾部无绘制、介绍不覆盖价格、价格中心几何、无注入流量行及字体继承断言。并发字体测试因fail-fast取消，不算产品字体失败。随后两个文件16项通过，覆盖两品牌四平台配置及窄/宽/字号；格式化后分析通过，golden/设备/新包未验。完整红绿结果见Docs/evidence/plan-list-layout-20261111，不把原型静态预览当客户端验收。

以下按事件留存历史，不同采集批次的未提交/候选/新包待验仅指当时。当前包归属查Docs/STATUS，不相加测试数或把后续制包倒填成早期设备通过。

### Windows ARM64 恢复准备（2026-11-11）

#### 逐次运行索引

同一错误在多个翻译单元重复出现，不计为多项产品缺陷；主动取消与取消前已发生的失败分别保留。

| Actions / run ID | 源码 | 结束阶段与实际结果 | 修复与后续证据 |
| --- | --- | --- | --- |
| #161 / 42955930995 | a46c9942 | 主动取消；取消前共享243项已有1项失败：首次/重试证据路径不一致。未到客户端编译 | 因远端A下一编号已为51停止旧分支默认编号尝试；重试路径遗漏随39b34efe修正 |
| #162 / 42956120276 | a46c9942 | failure；显式A51，仍在同一证据路径断言失败 | 保留断言补齐路径，#163共享前置通过 |
| #163 / 42956349173 | 39b34efe | failure；共享通过，ARM Runner WebView夹具11项6处失败，CMake4短/长路径误判越界 | WIN11同版真实红1→12绿；最终统一源目录及文件REALPATH后另2绿，#164原生前置通过 |
| #164 / 42958398408 | 9fd439eb | failure；原生前置通过，源码安装的Flutter未bootstrap，Dart ABI检查WinError2 | ea34df55先官方flutter --version再查真实ABI，后续完整入口继续验证 |
| #165 / 42960144515 | ea34df55 | 主动取消于符号工具预检；历史复查已发现后段生产准备器硬限x64。不是客户端编译失败 | 两品牌ARM符号旧代码红2，03263609按真实架构匹配；Windows16项通过 |
| #166 / 42962421116 | 03263609 | failure；共享通过，本地入口夹具4项中1项失败：auto实际选择amd64，未保留父进程注入的架构环境 | 不放宽预期，改由实际Dart SDK ABI选择Windows auto目标；保留显式目标ABI检查，本机10项及Windows正式Bash入口4项通过，ARM正式入口待复验 |
| [#167](https://github.com/wvjh3z/XFlClash/actions/runs/42963464788) / 42963464788 | 084c56ce | failure；首次进入实际ARM64 Package，教程插件使用experimental coroutine，被MSVC19.51的STL1011拒绝，退出255 | 插件PRIVATE兼容补修、Windows10项及82锚点通过；#168实际ARM64 Package成功，旧编译阻断已越过，设备另验 |
| [#168](https://github.com/wvjh3z/XFlClash/actions/runs/42972258074) / 42972258074 | 9d285ba7 | failure；Package与命名通过，最终PE检查拒绝vcruntime140_1.dll，Machine=0x8664；符号处理未执行 | 原版同名签名有效ARM64X样本可复现旧守卫误拒；仅增加已验证精确指纹识别，未知x64仍拒绝；#168本体未留存，新批次需核对 |

#### #168 原版运行库与架构校验

用户要求查询后取得完整日志，确认Package与Normalize均success，失败位于Verify final Windows PE architectures，明确报`vcruntime140_1.dll machine=0x8664`。这仅证明现有PE Machine守卫拒绝该文件；尚未取得该DLL本体及完整PE元数据，不能直接判定错误x64库混入，也不能推定它就是合法ARM64X双架构运行库。需核对实际复制来源、微软运行库版本/签名、CHPE/ARM64X元数据及目标加载契约，再决定修复构建输入或校验器。此前STL1011不再阻断本轮编译，但没有执行后续Sentry处理或设备安装；原包是否可取得/复用须先核归档，不因步骤success承诺可直接续跑。

后续按用户建议对照固定FlClash v0.9.3：windows/CMakeLists的InstallRequiredSystemLibraries块与品牌完全相同。下载原版ARM64 ZIP后，发现其同名DLL也为0x8664；Windows微软dumpbin明确显示“machine (x64) (ARM64X)”及混合arm64ec/x64代码范围，Authenticode为Valid/Microsoft Corporation，FileVersion14.51.36247.0。由此证明Machine字段不足以判断该运行库；不把PDB中的arm64ec文本或文件名单独当作兼容证明。官方语义见[Arm64X PE](https://learn.microsoft.com/en-us/windows/arm/arm64x-pe)。

修复只在自有windows_architecture检查器中加入该已验证DLL的精确SHA256识别，限制为ARM64目标、根目录vcruntime140_1.dll及0x8664，报告明确记为pinned-microsoft-arm64x-crt。不是按文件名跳过，不放行其他x64插件、不修改原版复制规则，也不是恢复客户端安装包下载hash校验。旧守卫在真实原版包上红于同一DLL；新守卫27个模块记录通过，实际DLL追加字节后准确拒绝并恢复原字节；普通同名x64、修改字节、改名插件负控继续拒绝。Python36项、Windows正式Bash5项通过。未来CRT更新需重新核对签名、格式和来源再更新指纹，不能添加通配豁免。

#168 artifact仅有报告，未保存其DLL/安装包本体，无法把原版样本当作#168原件，也不能复用已不存在的包只补跑审计。后续新构建只有产物字节确实匹配才会通过；Sentry和设备层仍待。证据统一见Docs/evidence/windows-arm64-v093-20261111/run168-fix.json及受限archive中的原版样本、dumpbin/签名回执；未执行下载的客户端。

<a id="windows-arm64-coroutine-167"></a>
#### #167 教程插件旧协程接口

Package日志的有效阻断均为同一STL1011/C2338，在多个翻译单元重复；CMP0175、C4244、C4458及Breakpad类型转换属于同时出现的warning，不把它们当作此次首错。锁定flutter_inappwebview_windows0.6.0用C++17和/await，经C++/WinRT进入experimental/coroutine；VS2026开始拒绝旧接口，错误本身给出专用兼容宏。微软[/await说明](https://learn.microsoft.com/en-us/cpp/build/reference/await-enable-coroutine-support?view=msvc-170)同时明确弃用和/await:strict的协程状态对象不兼容，因此未未经验证切换语言标准或协程ABI。

既有windows/CMakeLists.txt教程插件兼容块PRIVATE增加`_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS`，不加全局屏蔽、/WX-或修改Pub缓存。将来锁定插件改为标准协程后应连同此定义复核退役。既有Loader安装夹具扩展为两项兼容定义的作用域断言，并在MSVC下实际包含experimental/coroutine、使用/await编译；旧CMake绑定下因缺定义红1，修后WIN11-BUILD/MSVC19.44完整10项通过（两品牌、Debug/Release、默认/显式目录、MSVC/非MSVC分支与缺插件），82锚点命中。该红测证明缺少目标定义，并非在19.44上重现19.51原生STL1011；后者的失败证据来自#167，最终修复仍需新ARM Runner验证。

脚本复查覆盖release-package、release_request、prepare_release_context、release_pipeline、指定主机入口、windows_architecture、VC准备/运行时及Windows符号准备：沿实际归一目标和native ABI、包名、PE/ELF、PDB身份与上传阶段核对；原有x64/ARM64隔离及错误拒绝保持。#167已越过先前所有前置阻断，不能继续记为bootstrap失败，也不能因前置绿而宣称包已生成。正式复验从main最新固定源码派发，未沿用旧失败源码重跑。

#### 早期失败与修复沿革（#161–#166）

#166复现通过给shell环境保留AMD64、给受控SDK返回ARM64，旧auto规则稳定失败；这是环境/SDK架构混用，不能以放宽测试到任意目标解决。自动目标现在调用同一windows_architecture工具的--print-target，解析实际Dart版本ABI；未知、非Windows或多个ABI仍拒绝。显式windows-arm64仍校验真实SDK，不伪造硬件或允许x64包改名。普通Windows构建机实际--print-target返回amd64，显式amd64验证通过。

按用户提醒对照v0.9.1的Windows符号根目录/架构经验后，提前发现prepare_sentry_windows_assets仍只接受x64 hook及x86_64 runner。新增两品牌ARM64回归在旧生产准备器均失败于明确x64限制；改按实际hook架构映射runner并继续逐PE/PDB匹配ID及架构后通过，错架构PDB、错hook标签仍拒绝。WIN11-BUILD符号/架构16项通过，包含旧x64、路径别名及真实CMake清单夹具，未上传符号。同步发现指定主机脚本漏显式windows-arm64参数及Git Bash模拟架构误判，补目标解析、真实Dart ABI门禁和最终PE/ELF检查；14项本机定向通过。#165在发现这项必然阻断后主动取消于符号工具前置阶段，不记为ARM编译失败。

#164已通过共享前置、原生WebView、安装器与VC检查，停在新增Dart宿主检查WinError2：flutter-action源码安装分支仅检出固定Flutter，未运行bootstrap，bin/cache/dart-sdk/bin/dart.exe尚不存在。增加有界`flutter --version`先走官方初始化，再检查真实Dart ABI；不把missing executable当成ARM组件404，也不取消拒绝x64回退的断言。没有改SDK版本、共享缓存或生成工具文件，正式入口继续复验。

原生Runner #163通过共享前置后，WebView既有CMake夹具11项出现6处失败。Runner实际为windows-11-vs2026-arm64/20261101.203.1、CMake4.4.5、MSVC19.51。CMake4保留SOURCE_DIR的8.3短路径，get_filename_component(ABSOLUTE)却展开为长路径，RELATIVE_PATH因此将正常main.cpp误判越界。WIN11-BUILD隔离安装经官方SHA256验证的便携CMake4.4.5后准确复现；旧CMake对照正常。新增短路径/别名回归在旧helper下红1，源目录先REALPATH统一后完整12项通过，原工具链另2项通过；保留真实外部源拒绝、原版静态析构负控及源文件不变检查。该修改仅调整既有windows/xboard_webview_shutdown.cmake路径比较，不改COM所有权策略。

ARM Runner已切VS2026，不能沿用x64的MSVC19.44/CRT14.44最低要求。在同一固定离线payload策略中增加ARM64的MSVC19.51/CRT14.51.36247目标要求，按实际runner选择；x64原要求保持。选择、错编译器及不降级40项策略通过，实际ARM构建仍须核对其CRT文件版本，不能仅据Runner标签放行。

首次任务分支a46c9942的#161/#162在共享前置243项中出现1项失败：新增windows-architecture.json仅进入首次证据上传路径，重试路径漏项。保留EvidenceRetryContractTest的路径集合相等断言，补齐重试清单后定向通过，再用正式入口复验；未进入ARM64编译，不记为原生依赖失败。#161另因远端A下一编号已由50推进至51而取消，#162显式使用51且upload=false；不以隔离分支旧计数替代派发前远端核号，不改main计数或沿用旧包身份。

固定Flutter3.47.6的BuildWindowsCommand没有目标切换参数，按宿主选择x64/ARM64；因此不能用在x64主机安装ARM64 MSVC来证明正式Flutter整包可交叉构建。用户选择windows-11-arm原生Runner，WIN11-BUILD做既有x64/原生夹具检查。旧QuickJS x64 DLL与客服旧Loader阻塞已随依赖演进改变，不能照旧版失败禁用新目标，也不能由上游出包宣称品牌安装器/更新通过。

前置检查首次缺固定distributor源码，按checkout_distributor准备后通过。新宿主检查用未解析的dart批处理名触发WinError2，改为FLUTTER_ROOT内真实dart.exe后正控0、错误目标负控1。Windows app.so由AotElfRelease生成，成品守卫必须区分PE原生模块与ELF AOT；已复用现有ELF解析器，并覆盖两品牌的错DLL/错AOT负控。VC配置必须按实际runner生成，ARM64策略查ARM64注册表/编译器/CRT，而不是仅允许发行名称。40策略、9子进程、两品牌×两架构20项真实Inno编译及Dart4项通过；正式ARM64整包与设备结果见Docs的evidence/windows-arm64-v093-20261111（[初始证据提交](https://github.com/wvjh3z/proxy-suite-docs/commit/815464ee13d5f3bc5b3a4995720a1ccbd5ced7f4)，后续沿任务分支维护），本段不代替实际构建回执。

### 品牌分组菜单回归（2026-11-11）

本轮未提交分组/刷新适配在授权WIN11-BUILD隔离副本验证，Flutter3.47.6/Dart3.13.5。双次语义激活负控实测菜单和下方pager均消失，回调丢失；单次激活正常。Navigator在调用didPop前已改变entry状态，因此isFirst不能可靠识别不可弹出的根内容页。改为`settings is _GroupRootPage`后12项菜单回归通过，后续17文件分两批138+48项全部通过。仅保护品牌本地菜单Navigator，不能据此关闭原版全局P1。

测试准备失败分别处理：原版7.5行菜单末行半露且有弹性回弹，需真实滚动、ensureVisible并等待结束后再点，保留命中警告fatal；SemanticsHandle须在finally释放；新增内层PageView后旧全局Finder不唯一，改从页面标题真实拖动外层；漏import与桌面旧÷2断言属于编译/预期准备，不算产品负控。初始分析另纠正GlyphIcon导入、根路由父类调用及大括号；完整26文件分析通过，4个新文件格式化后再次分析/17项复验通过，最后一处仅大括号整理未重复行为回归。pubspec/lock已恢复、本机远端摘要一致；完整命令、红绿报告及归档索引见[本轮证据](https://github.com/wvjh3z/proxy-suite-docs/blob/main/evidence/node-group-client-20261111/README.md)。没有出包、安装或更新golden，设备视觉与正式交付仍待验。

### VC诊断编译与来源分类（2026-11-11）

2026-11-11 Windows VC诊断增强：固定Inno6.7.1真实编译揭示16项静态检查漏掉两处问题。错误兜底字符串换行以`#13#10`开头，被ISPP当作未知预处理指令；移到上一行后，编译继续暴露`TNewMemo.CopyToClipboard`未知标识符。PascalScript源码里的该注册受`IFNDEF PS_MINIVCL`控制，不能仅搜索到注册语句就认为Inno实际暴露接口。已改用原生编辑框`WM_COPY`及`GetClipboardSequenceNumber`核对复制是否发生。原始红编译退出2；修正后完整生产诊断Code/中英CustomMessages的无害夹具经Inno6.7.1编译成功，并以普通用户实际执行中英两种语言，覆盖UTF-8、中文/空格/单引号路径、入口/解析失败、原始退出1、协议分类、日志不可写及复制回读。38项策略和9项真实子进程另行通过，未安装VC或构建客户端。此夹具不含正式maker/Files/ISPP准备入口，不能替代双品牌完整预检。可复用夹具为`tool/test/windows_vc_diagnostics_native_test.py`；证据见Docs/evidence/vc-diagnostics-20261111。MCP首次超长内联传输触发WinError206，改分块传输；首次夹具收尾外层退出1，修正空剪贴板恢复及子进程清理后复验退出0，两者均非安装器缺陷。

同轮复核补修：先按数字分类再用协议覆盖，会在标记丢失时把VC退出1误判检查器错误，也会把VC退出4004误判内部超时。新增生产XbVcError调用回归，修复前四组均在missing protocol exit1 neutral红测；改为已确认本地来源优先、协议结果/kind/子进程码匹配才分类，否则中性提示后通过。原生Python入口原先只编译，现在连接版本化PowerShell驱动，英/中×复制正常/真实剪贴板占用四组最终均退出0，失败和清理异常非零，报告可重放。占用负控首轮确实显示错误但驱动误用IDOK导致超时，改为仅关闭已识别的Inno自定义错误窗WM_CLOSE后通过。清理不能靠进程名及启动前PID快照：现用私有Windows Job在恢复挂起loader前接管全部后代，kill-on-close防驱动异常遗留，核对ActiveCount=0；实测同名无关ping进程不受影响。保留完整maker、正式失败页布局/点击及真实redist安装恢复待验。最新证据为Docs/evidence/vc-diagnostics-20261111/review-fix.json；本轮静态检查另有一条旧case语法断言失败，按新的来源/kind约束更新后16项通过，并有上述原生红绿作为行为依据。

更新GET/浏览器后续复核补修：67项中7条目标失败定位到固定118底栏在1.4/1.5/2.0字号溢出，以及async*采样在取消/SocketException交错时未捕获异常。底栏/按钮改最小高度并允许短窗口滚动；采样桥显式持有上游订阅、传播暂停/恢复、幂等取消，正常流错误仍作为未确认源，不靠吞所有业务错误转绿。先用无配合close替身暴露等待，再用故障流与直接Dio对照、真实IO关闭区分边界；补修还覆盖无配合close及正常流错误。分析器对别名cancel未识别，改为直接调用subscription.cancel使真实收尾可追踪，未屏蔽cancel_subscriptions。最终74/74（含4既有golden）和分析通过，未改golden基线；证据见Docs/evidence/update-get-probe-20261110/review-fix.json，新包/设备仍待验。

更新GET轻量探测验证：仅在ResponseBody消费者累积样本后break不能保证有界，Dio5.11.1的响应处理器可能已提前订阅并缓冲原流。快速8MiB响应负控实测读完整流，改为在本轮HttpClientAdapter返回响应、交给Dio之前包采样上限，再由消费者读取并取消；原Dio/全局代理实现未改。用户随后指定每源100KiB（Range bytes=0-102399）。真实回环HTTP还验证重定向/忽略Range，服务端flush在客户端提前关闭后可能不完成，测试生产者独立限时收尾，不把服务端夹具等待当客户端探测超时。新增Widget夹具首轮遗漏XboardConfig.debug属加载失败，Dio异步派发的FakeAsync等待改为受控Completer握手；这些与业务断言分开。最终54项选源/浏览器/取消测试及4项既有更新弹窗golden通过，分析无问题，未更新golden基线；原生浏览器与新包仍待验。

品牌B build39派发准备：维护机执行共享预检因缺cmake在前置检查退出2，未安装工具链；授权Linux测试副本直接运行该入口时，固定flutter_distributor源码目录缺失，出现1个setUpClass及9个cold-start setUp错误（232项、0断言失败/10错误），不属于产品或GitHub Runner构建失败。必须按正式release setup既有顺序先checkout_distributor.py、prepare_linux_packager.py，再运行check_release_workflow.py；不能将此前Dart回归副本等同完整发行预检环境，也不能跳过准备夹具。原失败与完整准备后的结果由Docs/STATUS对应build39记录维护，本轮未修改发行脚本。

2026-11-10再次复核补修：此前319/25绿色没有覆盖传递重叠、真实HTTP归一化及双登录/退出动画；新增定向45项中5个目标失败对应四类业务缺陷，未弱化或跳过。SDK完整管线夹具首轮因import置于声明后而加载失败，与业务失败区分；修正位置后HTTP/panel366/366、客户端329/329通过，另窄/宽路由与旧接口15/15通过（部分重叠）。复核Token清理必须持有save返回的精确revision，不能在建立失败后凭Token文本重新寻找当前凭据，否则同值新登录会被误清。新增作用域API保持可选，旧login实现与测试替身仍能工作。规范/行为独立复核及最终校验见[补修证据](https://github.com/wvjh3z/proxy-suite-docs/blob/main/evidence/upgrade-v0.9.3/review-followup-fix-20261110.json)，不是正式构建或设备通过。

2026-11-10复查修复测试准备：SdkResult.success是非const工厂，错误const导致新增登录用例加载失败，不能计为业务红测。弹窗pop后需先pump启动退出动画，再推进时间并pump完成销毁；仅推进一帧时页面仍在，不能据此前置失败声称迟到认证已复现。修正夹具后登录/注册二步登录均实测停在authenticating，修复后完成认证；Core选择与嵌套测速保留真实动作链，仅控制Core I/O。Jenkins通道曾中断；在同一授权节点恢复后读取已落盘SDK报告，区分测试exit1与传输异常，再运行未完成客户端测试，不重启节点或扩大主机范围。最终相关回归319/319、SDK版本响应25/25；修改测试文件的既有悬空library doc注释被fatal-infos拒绝，补library声明后另行分析。源码/测试身份、正负控与未出包边界见[本轮证据](https://github.com/wvjh3z/proxy-suite-docs/blob/main/evidence/upgrade-v0.9.3/review-fixes-20261110.json)。

### Actions #151 Android协议夹具（2026-11-10）

发行#151（run42730612787，cb6e1e02，品牌B/build37）已越过私有SDK检出，五个桌面目标成功；Android品牌通道测试仍引用已移除的CoreMethod.getIsInit而加载失败，未执行测试/生成APK。修为coreInitialized后，还需将mock的null答复改为新版Uint8List JSON响应，并断言实际wireName为core.initialized及结果可解码，不能只换枚举后吞no_response。A/B生产define各4项、相关平台/协议94项通过；最后去掉冗余typed_data导入，分析无问题。全仓149处CoreMethod引用没有其他无效成员。五桌面8产物的清单大小与GitHub自动digest一致，符号macOS各8/8、Linux各18/18、Windows21/21；这是流水线证据，不代替设备验收。草稿保留的两个APK早于本轮，不能随草稿标题误称build37；bump因Android失败跳过，37已有桌面成品占用，下一批重新核号。未自动删草稿或重跑，见[本批回执](https://github.com/wvjh3z/proxy-suite-docs/blob/main/evidence/ci151-platform-check/result.json)。

### Actions #150 SDK认证（2026-11-10）

GitHub发行#150（run42686858157，53feef32，品牌B/build37）六个平台都在Checkout Xboard_sdk的clone阶段退出128，尚未进入应用编译。原助手按凭据隔离要求丢弃Git输出，不能仅凭128断言Token过期；同助手在维护机使用有效root凭据可检出211c6be，固定对象不存在不是当前证据支持的结论。新增手动xboard-ci SDK-only诊断使用CI实际Secret做仓库/commit API检查与真实检出，输出固定状态分类，不反射API正文或Git原始错误；默认模块CI行为保持。用户只授权一次轻量诊断，不能自动重跑发行矩阵；源代码修复需新构建输入，重跑#150仍使用旧53feef32。后续实际诊断与修复回执由Docs/STATUS维护。

后续诊断及授权同步后，#151六目标越过SDK检出，见[认证回执](https://github.com/wvjh3z/proxy-suite-docs/blob/main/evidence/ci150-sdk-access/initial-result.json)；保留以上原失败时点，不用后批成功改写#150。

build47/48交付与设备阶段：增量Git对象包必须包含提交的根tree（`ls-tree -r -t`仅列其后代），遗漏会在checkout报Could not read tree；补齐根tree后检出真实原提交，不以重建临时提交冒充原源码。Windows Java ProcessBuilder的`python -c`内联引号曾破坏安装驱动，改为base64源码解码执行，避免多层命令行重解释。Linux干净组合使用固定Python3.12.15解包；主机默认旧Python不支持extractall(filter=...)。这三项均为准备失败，不算产品缺陷。IP恢复测试需真实ProviderScope/XbIpCard调度监听；独立容器夹具的失败重试计数误差排除后，最终红17通过/1目标失败、绿32/32。build48设备稳定恢复/手动正控、账号清理及Sentry有独立证据，初轮额外IP查询仍未归因，详见[候选边界](https://github.com/wvjh3z/proxy-suite-docs/blob/main/evidence/upgrade-v0.9.3/windows-candidate-acceptance.md#build48验收与边界)。启动性能专项已由用户停止，不因此修改产品或继续采样。

剩余P1验证的准备失败：Core事件测试的受控Completer须在真实派发Zone创建，并同时排空真实微任务与FakeAsync帧；否则成功对照失败，不能算业务错误。Editor必须等待真实controller和保存按钮可用；真实SQLite单次写入后，若Provider在FakeAsync内销毁、数据库关闭在runAsync内等待，可卡在清理阶段。将销毁/关闭置于同一runAsync并加5秒超时后有效轮次完成。外层600秒超时曾杀掉flutter_check包装器，使pubspec两个build_assets=false未恢复；核对无遗留进程且恢复候选与来源副本逐字节相同后才重跑，不盲覆盖其他变更。再次误传字符串给testWidgets.skip导致三文件加载失败；修正为bool后默认3通过/5跳过，显式XB_VERIFY_UPSTREAM_P1为3通过/5失败，分析无问题。包装采集器把skip计入passed，正式摘要必须按testDone.skipped排除。用户决定上游问题等待上游修复，以上五个红色断言保留；[本批证据](https://github.com/wvjh3z/proxy-suite-docs/blob/main/evidence/upgrade-v0.9.3/remaining-p1-result.json)不代表成品或设备验收。

Prism语义补丁后经用户决定撤回：原版0.9.3同有该缺口，本轮保留固定上游，不为其fork。历史287绿测/84锚点不再描述当前全部状态，当前82锚点；三个语义期望用例默认明确skip、可用`XB_VERIFY_UPSTREAM_PRISM_SEMANTICS=true`显式复现。断言保留，不改成“缺动作也通过”，skip不计通过。回退准备中发现testWidgets.skip仅接受bool，原因改记测试名/注释，不把参数类型错误算成缺陷复现。当前结果见[处置记录](https://github.com/wvjh3z/proxy-suite-docs/blob/main/evidence/upgrade-v0.9.3/prism-upstream-decision.md)。

用户随后批准三项审计风险修复：回滚归属、旧setup载荷兼容和Prism语义动作。原6个红色断言已转绿，最终Dart287/287、Go协议22/22与相关6/6、4个JVM转交通过，84锚点/白名单/import/theme守卫通过；边界和来源见[修复验收](https://github.com/wvjh3z/proxy-suite-docs/blob/main/evidence/upgrade-v0.9.3/audit-risk-fixes.md)。新增测试首轮缺FunctionTag导入和错误const构造只是加载失败，修正后才计业务结果。Prism的源码dirty需保存固定基底可重放patch，不能把根gitlink未变当正式checkout已包含修复；当前尚未提交或出包。

最终覆盖审计后的风险验证只新增测试/探针。Profile真实notifier测试需订阅Profiles后再await自动释放的profilesStream.future；缺导入或provider提前dispose是准备失败，不能当作归属缺陷复现。语义handle要在测试体finally释放，不能等addTearDown越过框架不变量检查。Go缓存缺锁定依赖时尚未进入测试；同一授权节点补齐后核go.mod/go.sum未变。最终旧Android载荷、Profile迟到回滚、两处Prism语义tap共6个安全断言失败，6个对照通过，详见[风险验证](https://github.com/wvjh3z/proxy-suite-docs/blob/main/evidence/upgrade-v0.9.3/audit-risk-validation.md)。这些是已复现未修复，不是构建/设备通过；采集器退出0不覆盖底层测试退出1。

golden后续处理：先完成37张三方像素论证，再统一固定字体/环境夹具，先批准35张，套餐HTML两张经原型确认和公共配色修复后另行获批。Flutter内建对比度检查不覆盖任意RichText，须另验实际span；移除扩展的四项负控全部在颜色门槛失败，源码恢复后最终golden目录加配色测试55/55、分析零问题。新增链接点击测试需命中文字字形，不能点击占满宽度的RichText中心后误报回调丢失。临时审阅脚本循环变量曾覆盖批次标签为`font-prepare-*`，已按内容/摘要核实并修正变量；不得仅据预期文件名推断证据缺失。批准、复跑及归档统一见[golden论证](https://github.com/wvjh3z/proxy-suite-docs/blob/main/evidence/upgrade-v0.9.3/golden-adjudication.md)，没有触发正式CI或出包。

2026-11-09已复现缺口修复的最终回归：品牌3140例3103通过/37既有golden名称失败；存储184、SDK生命周期66、测速组合18项专项通过。SharedPreferences先以整表revision阻旧回包，新增权威键/无关键交错负控发现会丢整表刷新，改为逐键合并后通过；Token清理必须先确认新key未被权威记录引用，读取失败时保留而非盲删。取消保护后13项断言再次失败，已恢复源码并核验摘要。SDK不能把旧初始化失败的completer清理作用于新一轮；Riverpod容器存活使用捕获Ref.mounted，不使用内部disposed扩展。完整首轮的两个锚点失败是隔离副本缺sibling Docs输入，补齐并重跑后消除；Groovy驱动过长和Dart/Flutter分析参数差异另记准备问题。详见[修复证据](https://github.com/wvjh3z/proxy-suite-docs/blob/main/evidence/upgrade-v0.9.3/gap-fixes.md)，不宣称设备或发布通过。

2026-11-09后续缺口验证保留真实页面/provider/SDK调用，用受控I/O复现D04、G18、UB-GAP-22/27；没有修改生产实现，目标失败断言不是打包失败。五批86个用例中78通过、8个目标失败，另有ABI方法探针；逐项含义见[受控验证](https://github.com/wvjh3z/proxy-suite-docs/blob/main/evidence/upgrade-v0.9.3/gap-validation.md)。夹具首次失败须分开：RichText未匹配导致前置断言失败、WidgetTester虚拟时间不能推进真实Stopwatch、测试遗漏ProfileRecoveryOwner导入导致0业务执行。修正测试夹具后才计业务证据；手动恢复对照只清节流计时，不清业务结果。不得覆写testNode后用离页测试代替生产链，也不得用“特征断言通过”宣称缺陷修复。

剩余52项验证的初轮准备错误另记：选择线路spinner仍在运行时pumpAndSettle不会稳定，改为有限帧检查返回门禁，再解除受控等待；新增D07/G01夹具的const工厂/构造参数错误属于加载失败，修正后只重跑相关文件。最终去重784例中778通过、4个既知离页失败及2个门面reload交错失败，47项Python检查通过；[逐项证据](https://github.com/wvjh3z/proxy-suite-docs/blob/main/evidence/upgrade-v0.9.3/remaining-validation.md)明确模拟平台、helper/协议夹具与原生设备的界限。不得因为Tools导航测试吞渲染异常而宣称全部原生页面已验。

### Windows build45原生制包与普通用户采集

2026-11-09品牌A Windows候选build45首轮实际制包在CMake配置失败：WebView插件缺NuGet，jni0.14.2 FindJNI缺JDK头文件与JVM；已有Jenkins JRE不等于完整客户端构建工具链。CMP0175只是并行出现的警告。保持产品源码，补齐固定工具、官方摘要/签名和任务级JAVA_HOME/PATH后从package阶段续跑；结果与安装/运行边界见[候选原生验收](https://github.com/wvjh3z/proxy-suite-docs/blob/main/evidence/upgrade-v0.9.3/windows-candidate-acceptance.md)。首轮退出255、没有候选包，不能依据此前flutter doctor/工具版本检查声明制包通过。

第二轮已通过NuGet签名、VC下载和FindJNI配置，进入编译后flutter_secure_storage_windows报C1083缺atlstr.h。VS C++桌面基础工作负载不保证已装ATL；应核对`Microsoft.VisualStudio.Component.VC.ATL`及对应MSVC的atlmfc/include，不通过删除include、替换插件或复制不匹配头文件绕过。补组件前后核实际VS版本，继续同批增量构建，保留前轮失败记录。

ATL安装器退出8006时本次日志为VSProcessesRunning，不是组件下载失败。失败Flutter构建可能留下/nodeReuse:true的MSBuild及PDB服务；须核PID+启动时间+父进程退出+路径归属，再通过已核对的进程句柄清理，不按MSBuild名称全杀。本批仅清理7个复用节点和1个PDB服务，续跑进程关闭MSBuild节点复用。安装路径使用vswhere原生反斜杠字符串；本地化JSON需正确处理代码页，或仅读取安装路径/版本属性。

第三轮编译/打包退出0仍被fallback门禁拒绝：ZIP只有exe和WebView2Loader两文件。首轮CMake在FindJNI失败前缓存了默认Program Files/FlClash安装前缀，未到设置bundle前缀的语句；续跑时INITIALIZED_TO_DEFAULT已为false，完整资源安装到了错误目录。依据CMakeCache和install_manifest确认后，仅对临时构建缓存使用`cmake -U CMAKE_INSTALL_PREFIX -S windows -B build/windows/x64`，核前缀回到目标exe目录，再重打包并保留资源/符号门禁。不能只验证打包器退出码或直接补拷文件掩盖错误；无效包与错误安装清单保留，不作为候选验收输入。

build45最终制包/21项符号通过后，普通用户默认安装目录的原生崩溃验收仍失败：未设置nativeDatabasePath，Sentry Native的相对`.sentry-native`不可写。相同安装包/用户仅换可写cwd后出现Crashpad和原生dump，服务端事件`c149ea71668749a0aae9fb926ba1dae8`确认异常0xE0450045、release45、sdk=sentry.native.flutter；它与受控地址解析探针是两项证据。品牌自有初始化显式用用户cache路径，62项相关回归通过，修正包使用build46保持release可区分。标记存在、Dart SDK启用、符号上传及SYSTEM下成功均不能替代普通用户原生采集验收。

输入为旧品牌5ad809b2与目标上游be847366的未提交合并工作树，保留SDK4837b823；不是正式发行包。实际摘要和逐功能结论见[升级核查](https://github.com/wvjh3z/proxy-suite-docs/blob/main/evidence/upgrade-v0.9.3/README.md)。

- 依赖准备首轮遗漏pub_get_retry必需的`--report`，codegen首轮因新兼容桥漏闭合括号失败；修正后远端重生并校验导回48份生成/锁文件。两次均是实现/准备错误，不作业务负控。
- 17处分析错误来自测试接口迁移：AppleOptions、CoreOptions与testDelay。修正接线后analyze-r2零错误零警告。UI矩阵64例最初在测试框架不变量检查前未还原平台override，改为测试体finally后65/65通过；断开无应答测试改void+TimeoutException，设置页用真实Prism宿主及品牌桥，保留业务断言。
- 完整品牌第二轮3050例中3013通过、37项golden失败。补齐历史相同SHA256的Noto CJK字体后，以同Flutter3.47.6对照冻结旧品牌；720个旧源码/资源/测试/锁文件一致，旧新37张失败PNG逐字节相同。没有更新Flutter3.44.0历史golden基线来消红，真实生产宿主/设备视觉仍待验。
- Linux权限夹具先因受限TMPDIR祖先/umask077使nobody读不到probe而失败。使用本次进程可遍历TMPDIR与umask022后，uid65534的两品牌22场景及14次恢复通过；不修改生产权限。Windows上传只包含首入口而遗漏race脚本、VC JSON时失败；补齐依赖后37基础+14竞争+8进程边界通过，没有安装VC或修改实际用户数据。
- 身份CLI默认依赖未准备的distributor package_config导致解析失败；受控复验显式使用候选已解析的客户端package_config后通过，不能称正式打包环境已验。WebKit测试须用`python3 -m unittest tool.test.linux_webview_identity_test`保留仓库导入根；直接脚本启动的ModuleNotFoundError不是WebKit业务失败。
- 远端源码传输并不等于Git索引同步。首次白名单把已存在但未索引的上游新增文件当成删除，报71项；核对后只在临时验证仓将102个已传输上游文件纳入索引，再对真实be847366运行，未登记0项；未通过扩大白名单掩盖差异。76锚点全命中，seam-imports/theme-entrypoints通过。Groovy大文件传输需分段拼接，不能放入单个超过65535的字符串常量。
- Windows偏好专项首次已完成锁定pub解析和SDK codegen、2630文件前后摘要一致，但测试资源打包因缺`core/Clash.Meta/component/ca/ca-certificates.crt`退出1，实际0例执行。关闭native build hooks并不关闭Flutter测试资产打包；只排除Core源码仍需传输pubspec声明的CA资产。补入文件须与锁定Core024245dc原字节核对，不取active中历史CA脏副本；这次准备失败不是偏好业务失败，也不是负控。复验结果见升级证据。
- 新Windows偏好故障夹具首轮40例中36例通过、4例失败。阶段观测证明真实占用已使生产rename返回拒绝，超时发生在PowerShell标准输入释放握手；改为就绪/释放文件信号并消费输出。文件级deny Delete未形成有效故障（写入成功），改为目录deny CreateFiles并独立预检实际创建失败，保留缓存与落盘断言。PowerShell中文诊断可能不是UTF-8，诊断流容忍不可解码字节，仍严格检查进程退出码；未通过忽略生产异常或放宽提交断言消红。锁定Core中的CA文件是空占位，满足单元测试资产声明不等于正式包CA准备已验收。

Windows最终四文件40/40通过、0跳过；将临时验证工作区的偏好实现替换为未修复上游be847366原文件后，新增6例全部准确失败于缓存返回rejected值，负控退出1。finally恢复候选原文件，2630项初始快照摘要保持一致，新增测试有独立摘要，诊断输出已移除；本机未改生产偏好代码。真实故障与正负控摘要见[Windows偏好专项](https://github.com/wvjh3z/proxy-suite-docs/blob/main/evidence/upgrade-v0.9.3/windows-preferences-result.json)。安全存储/Sentry业务测试仍为替身，不宣称系统插件或完整应用重启通过。

上述修复未触发正式出包；真实AppImage/setup/APK/DMG安装、原生VPN、Keychain和候选Sentry符号不由夹具通过替代。Windows SYSTEM测试不代表普通用户交互。

## 偏好提交失败候选夹带（2026-11-08）

原版v0.9.2/v0.9.3及修复前品牌适配器先改Map再排队写盘；失败返回false却保留候选，后续无关键写入会把失败变更一起保存。真实SharedPreferences门面和文件故障证明该行为，不能因原9例通过就认为已有失败恢复覆盖。

按用户授权仅修改lib/common/preferences_store.dart：完整操作串行、候选副本、写成功后提交缓存、列表输入/输出隔离；不改getAll为每次读盘，不改Token补偿或业务退出策略。相同新目标用例先在旧实现25例中20失败，再在新实现九文件188/188通过；去掉测试冗余import后最终13例业务组合复验，定向analyze无问题。系统安全存储和原生Sentry仍为受控替身；Windows原生、真实进程重启、全局门面reload竞态及后置核验未知状态不由此关闭。

首轮白名单检查报12份既有自有文档未登记，核对它们不在固定上游且已有文档治理授权后补机器路径，保持守卫规则；最终74锚点、真实上游白名单通过，移除新存储登记的负控准确失败。源码、测试、差异、原始失败与复验归档见[提交修复证据](https://github.com/wvjh3z/proxy-suite-docs/blob/main/evidence/preferences-store-recovery-20261106/README.md#提交语义修复与验收2026-11-08)。未提交、未出包，不用源码修复替代设备验收。

## Jenkins本地工作区快照准备（2026-11-08）

测试最新未提交工作区时，依赖准备调用prepare_native_build.py的prepare_android_names，把build_config.yaml中core_name/helper_name的相同值加了双引号；全源摘要守卫因此在测试前拒绝继续。保存准备后的文件和失败回执，核对只有这两处格式变化，恢复已校验快照原字节后仅继续测试，不重跑会再次改写的准备步骤。最终四文件89例通过，测试前后3503项文件内容/链接/可执行标记一致。不能为通过而直接忽略全部build_config差异，也不能将依赖准备成功视为源快照始终未变化。

同次传输曾因Groovy单字符串常量超过65535限制失败；改为小段编码在运行时拼接，写入后校验完整摘要。传输/准备失败均未进入业务测试，不作为故障行为负控。快照、准备回执和结果见[最新工作区实测](https://github.com/wvjh3z/proxy-suite-docs/blob/main/evidence/preferences-store-recovery-20261106/README.md#最新工作区复验2026-11-08)。

## Jenkins测试采集器时区缺失（2026-11-08）

在既有Ubuntu22.04隔离环境中，测试采集器调用Python ZoneInfo('Asia/Shanghai')抛ZoneInfoNotFoundError，尚未进入源码准备和Flutter测试。采集器改用当前北京时间明确UTC+8偏移，核对失败只留下空任务目录后重新执行；实际14例测试通过，生产源码和断言未改。经验：预编译Python及隔离工具环境不保证IANA时区数据库可用，采集器元数据失败不能当业务负控或业务失败；时间必须带明确时区，不能回退为未知本地时间。原始失败回执、真实测试和后续待验层级见[偏好存储实测](https://github.com/wvjh3z/proxy-suite-docs/blob/main/evidence/preferences-store-recovery-20261106/README.md)。

## Jenkins Gradle计时无报告（2026-11-08）

缓存优化验证中，真实离线Gradle9.8.0任务成功，但通过init脚本设置`gradle.startParameter.profile=true`没有生成HTML，报告断言失败。不能由参数赋值或解析器单测通过推断已启用采集，也不能将缺报告归因于应用编译失败。

修正在外部维护源`infra/jenkins/project-builds/gradle_timings.py`及`gradle_task_timings.gradle`：临时init只对指定项目注册共享BuildService，以OperationCompletionListener接收任务完成事件；导出任务路径、数字耗时和结果枚举，finally删除init。真实成功任务和故意失败任务分别保持0/1退出码并产生对应耗时；本机损坏报告负控确认不覆盖原始构建错误。13项本机回归通过，三个任务v2配置linter/逐字回读通过。未重新编译完整APK，品牌/平台发行验收仍待后续获准完整构建。详细实测与恢复索引见[缓存优化证据](https://github.com/wvjh3z/proxy-suite-docs/blob/main/evidence/jenkins-codegen-cache-20261108/README.md)。

## Jenkins Android #2内存压力（2026-11-08）

品牌A build44、源码d119c532e813、新transit-linux-android节点。依赖/codegen完成后，Gradle与两个Kotlin JVM各允许4GiB堆，agent仅11GiB高水位/12GiB硬上限；实测内存约11.2GiB、PSI full约97%，长时间回收但未发生OOM kill。日志无进展不能据此直接判断网络或编译死锁，CPU忙也不证明编译有效推进。

#2由维护者中止，Jenkins ABORTED后仍有本任务JVM残留；必须核对任务环境标识和进程启动身份，定向清理，不能按java名称全杀。清理后内存约0.5GiB。当前节点Gradle用户配置改为4 worker、非并行、Gradle堆3GiB、Kotlin堆1GiB，保持12GiB硬上限与冻结源码；#3正式重编约11分46秒完成，APK身份/原证书/AOT及Sentry7/7通过。该成功证明本次资源预算可完成构建，不承诺其他缓存/负载条件的峰值；两次缓存热度不同，不将耗时差当严格单变量性能试验。设备仍待验。

唯一批次结果、配置恢复材料与独立File modified提示边界见[本次试编证据](https://github.com/wvjh3z/proxy-suite-docs/blob/main/evidence/jenkins-brand-a-build44-20261107/README.md#首次试编内存压力与恢复)。该修正为远端环境配置，不增加客户端接缝，也不据此提高用户授权的内存限额。

## Actions #140：v0.9.2首次全平台构建

### 运行身份与结果

- [运行链接](https://github.com/wvjh3z/XFlClash/actions/runs/40758021423)，run ID `40758021423`，Actions序号140，产品构建号39，品牌A。
- 分支 `upgrade/flclash-v0.9.2`，源码 `7dbd91bbc92325a6e7ef20692cbc5460e4e29d9e`。源码固定的SDK为`0ae4732249fce585525e548236ec4124d31fb2f0`；共享CI默认Docs固定引用`e46558b5c27c1744f5fdabe6175d8545894ad8a1`，不混同本地未提交文档。
- Android、Linux ARM64、macOS AMD64/ARM64任务成功；Windows AMD64、Linux AMD64任务失败；编号回写任务skipped。这里只确认任务结论，不新增逐项Sentry验收声明。
- 下载日志与Linux失败诊断附件存于本机`maintenance/run140`，日志可能含环境信息，不把原始日志整体提交。时间按北京时间：失败日志对应2026-10-29。

### Windows：身份竞态测试中的共享冲突

[失败任务](https://github.com/wvjh3z/XFlClash/actions/runs/40758021423/job/123062823574)。先通过37项基础清理检查；随后竞态测试10项通过、2项失败，分别为`omofly identity`、`daishu identity`，错误均为`The process cannot access the file because it is being used by another process.`。未进入客户端编译，也不能误归为VC运行库版本/下载或安装器ISPP问题。

源码路径为`tool/test/windows_brand_data_cleanup_race_test.ps1::ReplacedIdentity`：先枚举文件ID、打开再关闭子句柄，再移动旧文件、创建同名替代文件，最后确认旧ID被拒绝。现有顶层日志只给案例与异常message，没有分阶段位置/调用栈/原生错误码；因此能确认共享访问冲突，却不能据此断言某一个File.Move/File.WriteAllText/读取调用、Defender或某个生产句柄就是根因。Windows文件共享冲突依据见[Microsoft文件打开规则](https://learn.microsoft.com/en-us/windows/win32/fileio/creating-and-opening-files)。

待实施方向：先补夹具阶段、原生错误码及句柄释放诊断；必要时仅对夹具布置阶段的已确认暂时共享冲突做有限等待，并确认实际替换完成、对象ID确实不同，再进入生产拒绝断言。保留“移除身份检查就必须失败”的负控；不得用吞IOException、跳过案例、延长所有超时或放宽生产删除规则让CI变绿。需要原生Windows正式同入口及干净临时目录复验。

**后续改动是否覆盖**：当前停止脚本已退役，但该失败来自保留的安全用户数据删除竞态测试，不是停止脚本。`windows_brand_data_cleanup_race_test.ps1`及生产`remove_brand_user_data.ps1`相对#140源码无差异；因此仍未修复。此前自有Windows主机通过不能证明GitHub Runner同一竞态稳定。

### Linux AMD64：Go模块下载失败与独立待核诊断

[失败任务](https://github.com/wvjh3z/XFlClash/actions/runs/40758021423/job/123062823530)。Package期间`github.com/metacubex/bbolt`固定版本ZIP经`proxy.golang.org`下载报`stream error: stream ID 181; INTERNAL_ERROR; received from peer`，随后Native Assets/build_hooks失败、打包命令退出255。日志中的Sentry Clang警告不是已证根因；本次也没有证据说明是Linux AMD64业务代码编译不兼容。

同段还出现`File modified during build. Build must be rerun.`。目前工作流日志与已有附件未提供足够信息定位具体变化文件/写入者；不能把该诊断静默归并为网络错误，也不能据此宣称盲重跑必定成功。

代码核对：GoBuilder的依赖解析/构建仍直接调用Go命令；已有Pub依赖有限重试不覆盖Go模块获取。当前GoBuilder及prepare_native_build相对#140无差异。后续Windows安装器整理、取消客户端更新SHA256以及AppImage启动恢复均不处理此构建期路径。

待实施方向：依照[Go模块下载机制](https://go.dev/ref/mod#go-mod-download)，在原生hook执行前为固定模块依赖补受控预下载及有总预算的网络错误重试，覆盖实际平台/标签所需依赖，不更新go.mod/go.sum或关闭校验来绕过失败。非网络错误、摘要冲突及配置错误须立即失败。另补hook完整命令/输入变化诊断以定位File modified；不得将Native Assets编译整体循环重跑视为依赖重试。预检需覆盖空模块缓存、首次下载失败后成功、持续网络失败耗尽预算、非网络错误不重试，并与正式入口接线对照。

### 可复用经验与验收状态

1. 先区分测试夹具失败、依赖网络失败、编译失败、符号/打包验收失败；按最早有效错误定位，不能只看最后一个退出码。
2. 同一任务同时有多种诊断时分别登记证据与未知，不能用一种常见原因解释全部。
3. 已有“网络重试”必须核对具体覆盖的工具和生产入口；Pub的重试不等于Go、Rust或原生hook已覆盖。
4. 竞态夹具要区分布置失败和安全断言失败；自有主机通过不等于干净Runner共享访问条件相同。
5. 修复经验包含未覆盖的边界，不因后续改了其他代码将原故障标为关闭。

以上为初次审计状态；后续修复及当前验收见下节，不能继续将其理解为当前未实施。


### #140后续修复与预检（2026-10-29，未提交）

**Windows已实施**：只修改测试夹具，不改生产安全删除逻辑。ReplacedIdentity的原文件创建/正常打开、改名、创建替代文件及读回有明确阶段诊断；只对原生错误32/33做最多40次、每次间隔50ms的布置重试，其他错误立即失败。确认子句柄已关闭、替代文件ID不同，再执行不重试的生产旧ID拒绝断言，且必须命中明确的身份变化异常。真实共享句柄的释放后成功、持续占用耗尽上限、非共享错误立即失败均进入正式Windows入口。不能断言已找到#140当时的占用进程；这修复已证的夹具缺少暂时冲突处理/阶段诊断问题，仍需同一GitHub环境复验。

**Go已实施**：新增自有prepare_go_dependencies，经prepare_native_build --prepare-go接入GitHub、桌面指定主机和Android协调器。运行`go mod download`下载当前go.mod明确require的固定模块（含indirect），不执行编译，不修改版本、不关闭生产摘要验证。复用已有子进程清理/脱敏输出/取消及总预算执行器：最多3次、单次300秒、总预算720秒；HTTP/2 INTERNAL_ERROR/REFUSED_STREAM及Go HTTP临时服务错误可重试，checksum/security、版本/配置、认证等永久错误优先阻断。保留go.mod/go.sum及本地替换模块的前后摘要，变化即失败；每次先覆盖旧成功报告，结果写build/dependency-retries/go.json。Go准备与Rust既有两条各600秒命令合并的CI步骤上限改为35分钟，避免外层20分钟提前截断已声明预算。

**预检中发现并纠正的方案问题**：最初`go mod download all`在真实清单上增加51行go.sum（含依赖测试图），被新摘要守卫拦截；最终改用无all的固定require集合，真实正式准备入口通过且模块输入不变。这是依赖准备方案的预检发现，不将它冒充#140文件变化的已证根因。经验：新增预下载必须检查源码清单是否被工具改写，不能在测试空项目通过后直接推到正式构建。

**文件变化诊断进展**：已只读核对构建机锁定hooks_runner 1.5.0源码。DependenciesHashFile.updateHashes会将截止时间之后修改的依赖记为hash=1，并返回路径；调用处输出File modified提示，但日志未附路径。当前#140附件没有其依赖hash记录，不能恢复当时的具体文件或写入者，也不能判定与Go下载必然同因。新增自有native_hook_diagnostics只读取这些缓存中的file_system/hash=1条目，输出脱敏路径、记录数和解析异常计数；不导出environment或完整hook输出。CI always阶段采集build/native-hook-diagnostics.json并随既有证据附件保留。缺文件、解析失败和零标记不能被解释为已经证明没有变化。未修改或绕过上游hooks_runner/GoBuilder缓存语义。

**验证**：Windows构建机PowerShell5.1的正式用户数据清理入口37项基础+14项竞态通过；三组退回旧行为/移除身份保护负控命中预期失败，恢复后通过。Windows和VDS均执行真实Go、隔离空模块缓存、回环模块代理先503后成功、中文/空格路径验证；不用公网假包或生产凭据，也不编译Go代码。VDS正式python tool/prepare_native_build.py --platform linux --prepare-go通过，固定输入未变。Python离线正负控覆盖网络耗尽、永久错误、输入变化、取消、旧报告恢复与hook诊断过滤；共享工作流预检218项通过（随后追加取消回归单项及相关套件通过）；actionlint/ShellCheck与github-actions-validator静态检查通过。证据maintenance/run140-fix及windows-uninstall-race-fix-20261029的本轮输出；受控网络故障不等于复现公网HTTP/2连接本身。

该预检阶段仅工作区修复、尚无提交/新运行；后续提交及正式复验以本页事件索引的当前结论为准。没有新增/调整客户端底座接缝或新依赖，改动位于自有tool、已有构建脚本/工作流及文档；实施前已告知范围。

### #140修复再次审核：仍需补齐的两项边界（2026-10-29）

本轮只审核及受控复现，未改产品/工具代码。Windows生产remove_brand_user_data无差异；FixtureIo仅处理布置中的32/33共享错误，真实旧ID拒绝断言独立且要求明确异常，未发现放宽安全保护。Go固定命令、三次/总预算、永久错误优先及取消清理仍在；GitHub/桌面/Android准备入口均已接线。

确认两项P2遗漏，不能以此前预检通过关闭：

- prepare_go_dependencies直接在真实core目录执行，结束后才检查摘要。受控runner将go.sum改写后返回0，报告正确为passed=false/inputs_changed，但文件仍保留改写内容。因此当前只保证发现改写后阻断，不保证“不会改写源码”；已有回归仅检查报告，没有断言源码字节保持。建议在隔离模块清单中准备依赖，限制影响外部输入的配置，不盲目回写/覆盖可能同时被维护者修改的源码；覆盖失败、取消和恢复后的字节不变。
- native_hook_diagnostics的os.walk缺少onerror，受控目录枚举PermissionError后报告collected=true、files_scanned=0、changed_inputs空、read_errors=0。未读到数据与没有变化无法区分。建议记录遍历异常并明确完整/部分/缺失采集状态，同时补目录不可读与正常空结果的对照，不把零标记当构建无变化证明。

复现位于maintenance/run140-review/check.py与results.json，均只用临时目录和受控边界，没有操作真实Go模块、安装数据或触发构建。两项待修，原#140具体占用者和变化文件仍待GitHub证据。已有正负控和成功准备结果保持其原验证范围，不由本轮发现倒推它们未执行。

## 跨版本排障入口

| 错误类别 | 已有经验 |
| --- | --- |
| 编码、换行、中文路径 | v0.8.93 E4/E5/E6；v0.9.1 #133/#137：必须覆盖原生窄代码页与正式入口 |
| 短真实时钟与子进程清理 | v0.8.93 T3；v0.9.1 #129/#138：就绪确认、受控时间、真实回收分别验证 |
| 依赖网络与缓存 | v0.8.93 E2；v0.9.1 #124/#126；v0.9.2 #140：按工具和阶段限定重试，不能整体循环编译 |
| 夹具和成品不一致 | v0.9.1 #120/#136：真实容器、真实插件、单/双架构及最终成品契约 |
| Windows安全清理竞态 | v0.9.2 #140：布置重试与安全拒绝断言分离，不为测试通过放宽生产保护 |

## v0.9.2 #140：隔离下载及诊断状态补修（2026-10-29，未提交）

此前“下载后检测到源文件改写”和“遍历失败却报告空成功”两项遗漏已在工作区修复。本节取代上方再次审核的待实施状态，仍不等于GitHub正式构建复验完成。

- Go仅复制已登记的core与Clash.Meta模块清单到源码目录外的临时目录，下载命令在副本执行；完成、失败、取消后清理副本，不把生成的go.sum写回源码。副本go.sum生成/变化单独报告，副本go.mod变化仍阻断，原始摘要做防御性核对，不回滚覆盖维护者的并发编辑。忽略持久GOENV/GOFLAGS重定向，禁用workspace/工具链自动切换；保留显式环境中的代理/校验配置，拒绝指向源码检出的缓存路径。以真实Go解析副本replace元数据，只接受登记的./Clash.Meta本地映射，未知/绝对/上跳本地替换拒绝，避免副本仍指向外部源码。
- hook诊断schema2：至少读到一个合法记录且无错误为complete（合法空file_system也是完整）；目录/记录不存在为missing；遍历、链接、读取或结构错误为partial。collected仅对complete为true；部分结果仍保留已读到的有效变化条目。记录明确错误类别，不记录原始异常/环境内容。os.walk接入onerror，缺失file_system和无效条目不再当正常空结果。
- 回归覆盖隔离副本被改写后的成功/失败/取消、原始字节不变、危险替换/缓存/参数重定向拒绝；诊断遍历拒绝、合法空记录、缺失、部分记录及失败后恢复。Windows和VDS均预检真实Go回环代理/空缓存/中文路径，VDS正式prepare_native_build --platform linux --prepare-go通过，未编译客户端。后续正式GitHub结果待用户授权，不补造#140的原始变化文件。

本次不调整客户端底座接缝。构建失败经验的唯一维护源已按用户要求迁入客户端docs/build-failures，v0.8.93与v0.9.1原文保留并增加上述后续事件索引；外部Docs仅保留兼容导航。后续每次失败/修复按底座版本及运行编号更新对应记录。

本轮最终验证：Windows专项13项通过（含真实Go、空缓存、中文路径、原始摘要缺失时仅在副本生成、真实摘要冲突不重试）；VDS同一真实Go夹具及正式原生准备入口通过。共享矩阵前223项通过，随后新增的隔离go.mod改写阻断专项及相关套件通过；文档检查18项回归与27范围链接检查通过。证据maintenance/run140-fix/windows-go-results.log、vds-go-results.json及run140-review/final_native.py。本轮无提交/构建，CI的远端固定Docs SHA未伪造更新，待提交授权后同步跨仓引用。

## v0.9.2 #140：隔离修复后的再次审核（2026-10-29）

本轮只复核及受控验证，没有改实现。确认原始模块文件仍与隔离副本分离，固定命令/本地替换门禁有效；文档完整历史、客户端AGENTS与构建入口导航链接检查通过。发现两项P2遗漏：

1. **晚到取消被写为成功**：prepare的SIGTERM处理器只置位cancelled，execute返回0后，在临时副本清理/最终快照阶段不再检查该位。受控夹具在真实TemporaryDirectory清理完成时发送SIGTERM，结果passed=true、stage=complete，源码字节不变。说明源文件保护成立，但取消结果不应被宣称全部正确。建议把取消判定覆盖到完成与报告阶段，记录取消并阻止后续原生准备，而不只由下载runner负责；补下载成功后、清理时取消的正负控。
2. **指定主机的报告留存/采集接线不完整**：package_desktop_local.sh先执行prepare_native_build --prepare-go，后flutter clean；build_android_local的普通新构建也在native-inputs之后clean。go.json位于build/dependency-retries，会被清理；两入口没有native_hook_diagnostics的失败收尾调用（当前仅GitHub always采集）。建议将清理顺序与准备顺序对齐，或将本批报告保存在不会被clean删除的批次目录，并在成功/失败/取消收尾采集hook诊断，保持主命令退出码不被覆盖。新增回归应验证正式调用顺序与报告留存，而不只搜索--prepare-go存在。

受控证据maintenance/run140-isolation-review/check.py、result.json；未调用Go下载、Flutter clean、客户端构建或真实安装，没有修改源码清单。成功/失败/下载阶段取消的前序测试结论保留，但不覆盖上述晚到取消窗口。两项待修；GitHub #140的具体原始文件变化仍没有新增现场证据。

## v0.9.2 #140：晚到取消与指定主机诊断收尾补修（2026-10-29，未提交）

本节补齐上一轮审核的两项遗漏。Go隔离目录清理后、生成完成结果前再次检查取消；报告发布期间收到信号时改写为cancelled并返回128+信号（SIGTERM为143），原始模块输入不回写。报告写入失败不会遮盖已发生的失败/取消。仍不重试整个客户端编译。

指定主机通过XFLCLASH_DIAGNOSTICS_DIR将Go报告直接写入本次运行的持久诊断目录：桌面为.local-build/desktop-diagnostics/run-*，Android为批次diagnostics；GitHub未设置时继续原build/dependency-retries/go.json和always附件。桌面在必备工具检查通过后、实际准备操作前注册共享EXIT/INT/TERM收尾，捕获原退出码再调用诊断，成功、失败、取消都会尝试采集；Python路径输出固定UTF-8/LF，避免Windows Bash命令替换留下CR或中文编码失败。Android在原finally调用同一诊断器，锁/steps报告/诊断收尾错误只记录警告，不覆盖原协调器结果（仍为既有0/1语义，不冒充子命令的退出码）。

诊断器在指定目录写native-hook-diagnostics.json及finalization.json，后者记录main_exit_code与诊断完整性；缺失/部分记录仍按既有schema2明确标记。采集/写报告失败不替换原构建退出状态。报告路径独立于build，flutter clean不会清除本批Go证据；旧运行使用独立目录，Android续跑仍按原批次规则管理。

回归覆盖：下载成功后临时目录清理、报告发布时的晚到取消；成功、失败及诊断器自身失败的退出码；真实桌面脚本通过准备→clean→失败收尾（构建命令是无害替身）、正常EXIT和真实TERM；Android完整协调器替身验证clean后报告存在、失败与诊断异常不更改结果。VDS最终49项通过；本机Android协调器31项通过、共享预检231项通过、工作流/ShellCheck通过。Windows原生Python/Git Bash最终49项运行，47项通过、2项POSIX专属Android进程替身按条件跳过；两项在VDS均通过。Windows实际执行了桌面正式脚本替身、EXIT/TERM和UTF-8/LF路径检查，不将VDS测试冒充Windows验收。没有调用Flutter构建、Go编译或安装器执行。

改动只涉及自有构建工具、既有桌面/Android入口及测试，无新增底座接缝或运行依赖。维护经验：报告留存必须跨实际clean步骤验证；取消保护必须覆盖到清理及报告阶段；诊断属于收尾信息，不得变成覆盖主错误的新失败源。

本轮证据：maintenance/run140-finalization/vds-results.log、windows-results-final.log。Windows首轮隔离副本漏带公开JSON契约，补齐后重跑；随后发现Git Bash未在SSH默认PATH导致桌面测试跳过，显式使用既有工具后再次运行，最终只剩两项已明确的POSIX专属跳过。未为通过测试修改生产安全边界或安装新工具链。诊断是收尾时现存hook缓存的观测，若失败发生在hook执行前，不应据此断言标记来自本轮。

## #141：Windows夹具文件占用与macOS符号传输失败

2026-10-29只读核对，源码3b6a5fbb、品牌A/build39。Windows两品牌identity夹具rename-original native32/40次失败，不能认为#140测试修复已被正式Runner验收；macOS AMD64符号上传transport_error，随后GitHub CreateArtifact五次超时，不能据旧草稿DMG宣布成功。四目标成功及成品兼容缺口见[本轮证据](https://github.com/wvjh3z/proxy-suite-docs/blob/main/evidence/run141/README.md)。本轮只定位、归档和更新说明，尚未修复或重建。后续正负控应分别覆盖Windows真实共享访问/重命名阶段、上传网络错误与诊断留存，保持生产安全保护和原退出码。

### #141工作区修复与原版支持基线核对（未提交、未构建）

Windows夹具不再带着整条锚定目录句柄执行路径File.Move：记录旧child和parent身份，确认所有句柄关闭，替换文件后重开同一parent并核对volume/low/high一致，再检查新child与旧ID不同、执行原生产拒绝断言。保留40次布置重试边界、junction等保护，生产删除脚本字节未改。原生PowerShell5.1的37项基础与14项竞态通过；新增LegacyIdentityNegative省略expected，两品牌必须命中REPLACED_IDENTITY_ACCEPTED，不能把夹具布置失败算作安全负控成功。此修复消除夹具自己持有的目录句柄这一干扰，不声称已经确定#141的具体外部占用进程。

符号CLI仅明确transport_error/server_error最多3次尝试，等待2/5秒，共享原900秒总预算；认证、权限、输入、未知错误、429和单次超时不新增重试，最终仍需原有成功终态与逐ID确认。CI证据上传首次失败仅再传一次，使用同名overwrite避免半完成artifact冲突；取消不重试，第二次失败保持失败，不掩盖原制包/符号错误。新增回归进入既有测试入口，52项选定离线回归通过，VDS运行github-actions-validator原脚本lint-only通过。真实网络故障恢复和新GitHub构建待验，未宣称#141历史运行恢复成功。

用户最终要求系统版本跟随原版0.9.2，因此未修改macOS12工程/Podfile或Linux依赖/Runner。原版官方ARM64 DMG亦含三个minOS13文件；本项目不自行提高支持下限。证据、当前边界及后续设备要求见[修复验收](https://github.com/wvjh3z/proxy-suite-docs/blob/main/evidence/run141-fix/README.md)。

#143正式复验：2026-10-29，源码a3152f5b、品牌A/build40，Windows及macOS AMD64正式入口、出包与符号处理成功；全部六目标成功，证据留存及10个草稿资产核对通过。此结果提供新批次正式复验，不改写#141失败，不代替两品牌设备验收，详见[本批证据](https://github.com/wvjh3z/proxy-suite-docs/blob/main/evidence/run143/README.md)。

## v0.9.2：隔离 Widget 预检的包图与着色器（2026-10-29）

出口IP定向回归首次仅复制package_config.json，Flutter在加载测试前因缺package_graph.json退出；改为在隔离副本对SDK/client执行缓存离线pub get。随后`--no-test-assets`下首个Android水波纹加载material_ui/ink_sparkle.frag失败，84项通过、1项为资源异常；IP时序测试不验水波纹，使用NoSplash测试主题，生产主题不改。需要验证字体/着色器/金图的任务应准备真实测试资产，不能套用此省略选项。测试副本按CI机制关闭setup/rust_api的build_assets，不能把该副本用于制包。静态检查使用Flutter analyze入口；Dart CLI不接受`--no-fatal-infos`，不得把命令用法错误当作源码分析结果。最终预检证据与未出包边界见当前Docs/STATUS。


## v0.9.2订阅恢复预检：Windows占用错误码（2026-11-01）

这是修复预检失败经验，不是新增Actions构建失败。Dart3.13.5真实Windows占用文件的rename可返回5，初版仅重试32/33的正控不能恢复；先排除只读/目录后纳入5有限重试，持续占用仍停止并保留旧文件。不能把旧File.copy的183当成单一占用证据。两品牌共享实现的原生正负控与VDS结果见[正式预检记录](https://github.com/wvjh3z/proxy-suite-docs/blob/main/evidence/subscription-recovery-fix-20261101/README.md)，仓库入口为[windows_profile_file_write_test.ps1](../../tool/test/windows_profile_file_write_test.ps1)。无构建/发布复验，不替代用户Windows10现场和Android真机验收。

同日复核发现只包rename的重试漏掉FileShare.None独占读取锁，原生两品牌参数均读取失败32且等待0次。补修后首次读取及目标复查/rename共享三次重试预算，永久只读仍立即拒绝；22组Windows原生与133项VDS回归通过。旧失败对照和最新结果均保留在上述证据记录，不以允许读取的句柄测试替代独占读取负控。

恢复标记隔离预检补充：初版在Object?经Map检查后将变量捕获到any回调，Dart未保留该处类型收窄，VDS/Windows两入口均编译拒绝。改为在已收窄作用域取出字段值，再在回调校验值类型；不通过强制动态访问放宽schema/身份检查。复验与归档见订阅恢复记录的后续标记隔离章节。此为未发布修正的测试编译失败，不是GitHub构建失败。

权限专项预检补充：真实nobody负控揭示Dart文件删除也可将受限查询表现为ENOENT，不能只按错误码忽略；增加独立存在性确认。Windows ACL夹具恢复旧FileSecurity对象可能不写回未标记变更的Access段，需显式重建/设置Access段并验证恢复。对应拒绝与恢复证据在订阅恢复记录“路径查询与删除缺失确认补修”，不通过改全局权限或safe.directory绕过。

Windows测试控制器长时间无返回时，先检查是否已创建本批隔离目录及是否有Dart进程，区分启动前传输和用例执行。此次大JSON夹具传输阶段未进入测试，改压缩文件传输后沿原入口复验；不要一再增加产品或用例超时来掩盖控制器问题，底层传输原因未定则保留该边界。

暂存清理专项：不能用“整个目录权限被拒绝”的负控替代部分删除失败。递归清理可能先删owner.json再在previous.yaml占用处失败；应让本次和历史清理共用明文→标记→空目录的非递归顺序，并用真实publish/commit＋备份句柄占用＋释放后重入验证。归属标记保证持续到明文已删；最后只剩空目录的删除失败单独记录。证据见订阅恢复记录“本次与历史恢复的统一有序清理”。
