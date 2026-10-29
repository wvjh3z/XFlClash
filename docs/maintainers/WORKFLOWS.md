# 日常维护与交付流程

先完成[HANDOVER](HANDOVER.md)，查[当前基线](UPGRADE_BASELINE.md)。下面的命令按前提选择执行，不把整页顺序粘贴为自动脚本。完整专项操作由Docs/DEVELOPMENT维护，本页负责跨AI任务编排和入口。

## 只读审计或文档任务

**输入**：用户问题、实际仓库/分支、必要截图或运行编号。**动作**：检查三仓Git状态；按功能ID追生产调用和测试，区分源码与成品。**输出**：可证结论、代码位置、影响品牌/平台、未确认及原因。不要为“审核”自动构建、安装、退出客户端或切换VPN。

本机允许的基础检查（在客户端根执行）：

```bash
git status --short --branch
git diff --check
git -C ../Docs diff --check
python3 ../Docs/tools/check_docs.py
python3 -m unittest discover -s ../Docs/tools -p test_check_docs.py
```

检查新文档是否会随提交交付：`git ls-files -- docs` 和 `git status --short --untracked-files=all docs`。未跟踪不等于已入Git；被忽略的文件不能靠“本机存在”验收。普通文档任务不执行文档里的联网、恢复或安装代码块。

## 代码修复与回归

1. 先确定客户端、SDK、插件或底座责任；Xboard主程序只读。若问题是接口/模型在SDK处理，UI行为在客户端，不能通过页面重复解析或修改主程序绕开。
2. 保存已有差异，改动只覆盖本任务。机器生成文件经其生成器更新，不手填临时运行结果。接缝操作执行UPGRADING规则。
3. 按风险选择实际回归：源码/轻量工具测试可在维护机；Flutter、Dart及原生测试使用已授权环境，并确认不会隐式编译不允许的原生资产。不要为了跑测试在本机安装工具链。
4. 在构建机传送冻结的候选源码及必要公开配置，核对摘要/提交；临时副本需包含真实入口的依赖，不能靠宿主未登记缓存补齐。失败时记录是准备失败还是待测行为失败，不把跳过写成通过。
5. 根据[功能对照表](UPGRADE_BASELINE.md)覆盖同类品牌/平台；补失败、取消、迟到结果与旧实现负控，保留主错误。设备/成品不能由替身通过代替。

当前可选轻量命令：

```bash
# 本机Python工具回归，读取/写入隔离临时夹具，不构建客户端。
python3 -m unittest tool.test.prepare_go_dependencies_test tool.test.native_hook_diagnostics_test
# 仅固定工具已存在时检查；缺失时按DEVELOPMENT准备，不擅装工具链。
python3 tool/check_workflow_lints.py
```

Flutter测试、原生PowerShell/MSVC/ISCC、真实Go预下载等命令见各功能回归入口和DEVELOPMENT，执行前确认主机与授权。`tool/check_release_workflow.py`为矩阵前共享预检；同一源码和环境的已通过检查不机械重跑，新增改变/失败/未解决风险才扩展验证。

## 构建失败处理

**输入**：真实Actions序号或Jenkins批次；先查ACCESS的只读方法。**顺序**：

1. 核对head_sha/head_branch/flavor、产品构建号和目标，不能把#运行号当APK版本码。
2. 收齐失败job首错及前后上下文，分清预检、依赖、编译、制包、验收/符号。不要只看最后退出码；同一次可能有多个独立原因。
3. 查[版本化经验](../build-failures/README.md)，对比本机与干净Runner的命令、环境、依赖、缓存、路径及时序。
4. 已有产物可用于只读复验时优先复用，不为符号工具问题重新编译。负控要命中被测缺陷，不把缺依赖、超时或传输失败当有效负控。
5. 修复后在同一正式入口预检，归档根因/未知、变更、测试及未验证事项；只有用户另行授权才能再构建。多平台构建失败后集中处理，不能逐改逐派发。

诊断目录和收尾规则以DEVELOPMENT为准：GitHub证据artifact、指定主机持久批次报告与原退出码分别核对。采集缺失/部分数据不代表“没有文件变化”；历史草稿资产不代表本轮成功包。

## 提交与跨仓固定引用

仅在用户已授权提交/推送时执行。先检查上游远端变化，再明确暂存本次文件；不整仓回退他人改动，不提交Core临时CA、私有配置、Token、签名或测试输出。

1. SDK有改动时先通过对应检查并提交/推送SDK；无改动就保持pin，不为形式制造提交。
2. Docs有改动时提交/推送当前Docs分支，取得真实commit。文档新路径需在本次客户端暂存中存在；未推送之前的GitHub链接可能404，不能据此删除正确文件。
3. 更新客户端实际消费者：[release-config](../../tool/release-config.json)的sdk_ref、[xboard-ci](../../.github/workflows/xboard-ci.yml)的sdk_ref/docs_ref。核对所有引用，不写不存在的SHA。
4. 客户端暂存前检查内容、忽略规则和接缝登记；运行必要守卫。提交遵守现有`[xfork] type(scope): subject` hook，不用no-verify掩盖失败。
5. 推送指定升级分支并确认远端SHA；未获授权不合并main、不改默认分支、不触发构建。

可执行的只读交付检查：

```bash
git diff --cached --name-only
git diff --cached --check
git diff --cached --name-only core
git var GIT_AUTHOR_IDENT
```

若`core`出现变更，先判断是明确授权的gitlink还是临时CA，不自动纳入。具体提交文件清单和消息由本次实际修改填写，不提供可误用的`git add .`模板。

## GitHub正式构建（需单独授权）

使用仓库Actions中的 **Release Package**，不是历史上游workflow或维护机直接Flutter命令。用户授权构建后，在Run workflow选择实际活跃升级分支并核对远端SHA，填写（用户已要求今后 GitHub 默认全平台；除非本次明确另定，target 选 all，不能沿用网页默认 android）：

| 字段 | 含义 / 判断 |
| --- | --- |
| flavor | brand_a或brand_b；缺少品牌且不能从当前授权确定时先确认 |
| target | all表示Android及所有已配置桌面目标；平台矩阵由workflow生成，不虚构iOS/Windows ARM64 |
| build_number | 留空使用该分支现有编号规则；指定值必须是用户给定/授权值，不能用Actions序号 |
| upload | true发布草稿；false不发布包但仍进行既有符号处理，不能当“无外部操作” |

没有网页/gh的工具环境，可在已授权认证下用标准GitHub `workflow_dispatch` API；请求参数以当前workflow为准。派发前列已有运行，成功返回后按新run ID、分支、SHA确认一次；超时结果不明先查是否已创建，不盲重发。后续是否监控听从用户安排。

验收顺序：逐job完成 → 真实目标资产/版本/签名/架构/fallback与资源 → Sentry逐项处理 → 草稿身份与是否混入旧包 → 设备安装和业务。任一层缺证据写待验，不把全绿等同用户能登录/连接/更新。

## 交接完成标准

按[ACCEPTANCE](ACCEPTANCE.md)逐项判断本轮范围，通过层级与待验边界分开表述；测试与必要证据按[MATERIALS](MATERIALS.md)归位。未提交资料只在当前工作区可见，不能称新机器已可取得；提交或正式交接仍需本次授权。

## 专项操作导航

这些链接指向当前升级 Docs 的负责章节。先核对其前提、主机和版本，再执行；章节中的历史验收只证明对应批次。

| 要完成的工作 | 唯一详细步骤 | 完成条件 / 失败时 |
| --- | --- | --- |
| 准备私有SDK认证 | [CI源码认证](https://github.com/wvjh3z/proxy-suite-docs/blob/upgrade/flclash-v0.9.2/runbooks/BUILD_RELEASE.md#ci-的-sdk-源码认证) | 拉到指定commit；权限失败保留主错误，不改成公共替代依赖 |
| 缺品牌输入或签名 | [配置恢复](https://github.com/wvjh3z/proxy-suite-docs/blob/upgrade/flclash-v0.9.2/runbooks/BUILD_RELEASE.md#品牌配置遗失与-github-secrets-恢复) | 正式包身份/原签名/fallback实际通过；缺原签名不能生成新签名冒充升级 |
| 选择代码回归 | [按改动选验收](https://github.com/wvjh3z/proxy-suite-docs/blob/upgrade/flclash-v0.9.2/DEVELOPMENT.md#按改动选测试和验收) | 记录同源码、正式入口、正负控及跳过；缺平台则保留待验 |
| 核对符号 | [生成匹配上传](https://github.com/wvjh3z/proxy-suite-docs/blob/upgrade/flclash-v0.9.2/runbooks/SENTRY.md#四平台符号生成匹配与自动上传) | 包与debug ID匹配、服务端逐项确认；上传成功与真实崩溃解析分开 |
| 只补传已有符号 | [已有符号补传](https://github.com/wvjh3z/proxy-suite-docs/blob/upgrade/flclash-v0.9.2/runbooks/SENTRY.md#已有符号补传与本地上传凭据) | 必须匹配该成品；没有匹配符号就记录缺口，不重新编译替代 |
| 测试失败后取证 | [指定主机报告留存](https://github.com/wvjh3z/proxy-suite-docs/blob/upgrade/flclash-v0.9.2/DEVELOPMENT.md#指定构建机的诊断收尾与留存) | 原退出码不被收尾覆盖；采集完整/部分/缺失分别报告 |

### 自动化派发的接口契约（只在获准构建后使用）

POST `https://api.github.com/repos/wvjh3z/XFlClash/actions/workflows/release-package.yml/dispatches`。

下列JSON是**品牌 A 全平台草稿的请求示例，不代表当前任务授权**；ref须与实际目标及远端提交核对。品牌B只有在明确授权B时改flavor；构建号留空使用目标分支编号。

```json
{"ref":"upgrade/flclash-v0.9.2","inputs":{"flavor":"brand_a","target":"all","build_number":"","upload":"true"}}
```

204表示接受派发，不表示构建成功；回到ACCESS的GET方法确认新运行及源码。使用具Actions写权限的认证，但不得将Token写入命令历史、JSON文件或日志。请求超时先查询运行记录，不立即重复POST。
