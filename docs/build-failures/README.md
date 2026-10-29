# XFlclash 构建失败经验（唯一维护入口）

<a id="构建失败经验索引"></a>

本目录随客户端代码和分支维护，适用于两个品牌、GitHub Actions、Jenkins及指定构建机。排障及修复交付必须读取和更新，见客户端[AGENTS](../../AGENTS.md)。当前升级分支及后续版本的失败事件在此维护；历史记录保留在 [v0.8.93 复盘](v0.8.93.md) 和 [v0.9.1 Jenkins/Actions 复盘](v0.9.1.md)，不复制其正文。当前操作步骤以 [DEVELOPMENT](https://github.com/wvjh3z/proxy-suite-docs/blob/main/DEVELOPMENT.md) 为准，归档硬性要求见 [CONVENTIONS](https://github.com/wvjh3z/proxy-suite-docs/blob/main/CONVENTIONS.md#构建失败后的修复经验必须归档硬性约定)。

记录区分“失败已确认”“修复待实施”“受控验证通过”“正式构建复验通过”，不能由后续不相关改动或一次本机成功替代。每次修复更新原事件，记录实际提交/工作区状态、正负控、正式入口及未验证边界，不另建重复事件。


## 按底座版本查阅

| 底座版本 | 经验记录 | 适用范围 |
| --- | --- | --- |
| v0.8.93 | [完整历史复盘](v0.8.93.md) | 历史事件及跨平台教训；不是当前工具链指南 |
| v0.9.1 | [Jenkins与Actions复盘](v0.9.1.md) | 原生资产、平台打包、符号和远端构建经验 |
| v0.9.2 | [#140及后续修复](#actions-140v092首次全平台构建) | 当前升级分支；已实施与待复验分别记录 |

跨版本排障先按错误阶段搜索三个文件，再核对该事件源码、版本、架构和验证边界；不要把旧配置直接应用到新底座。新版本增加版本项，每个事故在对应记录维护，不丢弃旧经验、不复制同一事实到两处。

## 事件索引

| 事件 | 品牌 / 目标 | 首个失败阶段 | 当前状态 |
| --- | --- | --- | --- |
| [Actions #140](#actions-140v092首次全平台构建) | A / Windows AMD64 | Windows runtime prerequisite rules：identity竞态夹具 | 夹具稳定性与诊断已修复，原生预检通过；GitHub待复验 |
| [Actions #140](#actions-140v092首次全平台构建) | A / Linux AMD64 | Package：Native Assets Go依赖获取 | 固定依赖预下载/有限重试已实施；文件变化已补采集，GitHub待复验 |

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

当前仅工作区修复，无修复commit，未提交、未构建；#140失败尚未通过新GitHub运行关闭。没有新增/调整客户端底座接缝或新依赖，改动位于自有tool、已有构建脚本/工作流及文档；实施前已告知范围。

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

2026-10-29只读核对，源码3b6a5fbb、品牌A/build39。Windows两品牌identity夹具rename-original native32/40次失败，不能认为#140测试修复已被正式Runner验收；macOS AMD64符号上传transport_error，随后GitHub CreateArtifact五次超时，不能据旧草稿DMG宣布成功。四目标成功及成品兼容缺口见[本轮证据](https://github.com/wvjh3z/proxy-suite-docs/blob/upgrade/flclash-v0.9.2/evidence/run141/README.md)。本轮只定位、归档和更新说明，尚未修复或重建。后续正负控应分别覆盖Windows真实共享访问/重命名阶段、上传网络错误与诊断留存，保持生产安全保护和原退出码。

### #141工作区修复与原版支持基线核对（未提交、未构建）

Windows夹具不再带着整条锚定目录句柄执行路径File.Move：记录旧child和parent身份，确认所有句柄关闭，替换文件后重开同一parent并核对volume/low/high一致，再检查新child与旧ID不同、执行原生产拒绝断言。保留40次布置重试边界、junction等保护，生产删除脚本字节未改。原生PowerShell5.1的37项基础与14项竞态通过；新增LegacyIdentityNegative省略expected，两品牌必须命中REPLACED_IDENTITY_ACCEPTED，不能把夹具布置失败算作安全负控成功。此修复消除夹具自己持有的目录句柄这一干扰，不声称已经确定#141的具体外部占用进程。

符号CLI仅明确transport_error/server_error最多3次尝试，等待2/5秒，共享原900秒总预算；认证、权限、输入、未知错误、429和单次超时不新增重试，最终仍需原有成功终态与逐ID确认。CI证据上传首次失败仅再传一次，使用同名overwrite避免半完成artifact冲突；取消不重试，第二次失败保持失败，不掩盖原制包/符号错误。新增回归进入既有测试入口，52项选定离线回归通过，VDS运行github-actions-validator原脚本lint-only通过。真实网络故障恢复和新GitHub构建待验，未宣称#141历史运行恢复成功。

用户最终要求系统版本跟随原版0.9.2，因此未修改macOS12工程/Podfile或Linux依赖/Runner。原版官方ARM64 DMG亦含三个minOS13文件；本项目不自行提高支持下限。证据、当前边界及后续设备要求见[修复验收](https://github.com/wvjh3z/proxy-suite-docs/blob/upgrade/flclash-v0.9.2/evidence/run141-fix/README.md)。
