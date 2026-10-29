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
5. 推送本次授权的目标分支（当前默认维护main）并确认远端SHA；未获授权不合并main、不改默认分支、不触发构建。

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

这些链接指向当前main Docs的负责章节。先核对其前提、主机和版本，再执行；章节中的历史验收只证明对应批次。

| 要完成的工作 | 唯一详细步骤 | 完成条件 / 失败时 |
| --- | --- | --- |
| 准备私有SDK认证 | [CI源码认证](https://github.com/wvjh3z/proxy-suite-docs/blob/main/runbooks/BUILD_RELEASE.md#ci-的-sdk-源码认证) | 拉到指定commit；权限失败保留主错误，不改成公共替代依赖 |
| 缺品牌输入或签名 | [配置恢复](https://github.com/wvjh3z/proxy-suite-docs/blob/main/runbooks/BUILD_RELEASE.md#品牌配置遗失与-github-secrets-恢复) | 正式包身份/原签名/fallback实际通过；缺原签名不能生成新签名冒充升级 |
| 选择代码回归 | [按改动选验收](https://github.com/wvjh3z/proxy-suite-docs/blob/main/DEVELOPMENT.md#按改动选测试和验收) | 记录同源码、正式入口、正负控及跳过；缺平台则保留待验 |
| 核对符号 | [生成匹配上传](https://github.com/wvjh3z/proxy-suite-docs/blob/main/runbooks/SENTRY.md#四平台符号生成匹配与自动上传) | 包与debug ID匹配、服务端逐项确认；上传成功与真实崩溃解析分开 |
| 只补传已有符号 | [已有符号补传](https://github.com/wvjh3z/proxy-suite-docs/blob/main/runbooks/SENTRY.md#已有符号补传与本地上传凭据) | 必须匹配该成品；没有匹配符号就记录缺口，不重新编译替代 |
| 测试失败后取证 | [指定主机报告留存](https://github.com/wvjh3z/proxy-suite-docs/blob/main/runbooks/PLATFORM_REGRESSION.md#指定构建机的诊断收尾与留存) | 原退出码不被收尾覆盖；采集完整/部分/缺失分别报告 |

### 自动化派发的接口契约（只在获准构建后使用）

POST `https://api.github.com/repos/wvjh3z/XFlClash/actions/workflows/release-package.yml/dispatches`。

下列JSON是**品牌 A 全平台草稿的请求示例，不代表当前任务授权**；ref须与实际目标及远端提交核对。品牌B只有在明确授权B时改flavor；构建号留空使用目标分支编号。

```json
{"ref":"main","inputs":{"flavor":"brand_a","target":"all","build_number":"","upload":"true"}}
```

204表示接受派发，不表示构建成功；回到ACCESS的GET方法确认新运行及源码。使用具Actions写权限的认证，但不得将Token写入命令历史、JSON文件或日志。请求超时先查询运行记录，不立即重复POST。

## 回归入口选择

只在具备工具链且已获授权的测试主机执行；本机不恢复工具链。以实际文件内容和正式workflow/preflight为准，不能按扩展名猜测入口。`tool/test/`有独立Dart main脚本，禁止整目录套用flutter test。

| 类型 | 正式入口／前提 |
| --- | --- |
| 客户端Flutter套件 | `python tool/flutter_check.py --no-pub <明确测试文件>`；工具临时关闭setup/rust_api原生build_assets并在finally恢复；先准备依赖/codegen，不能把禁用hook的副本用于发布 |
| 模块CI工具测试 | 文件白名单取`.github/workflows/xboard-ci.yml`，客户端AGENTS同步同一入口，不额外递归执行tool/test |
| AppImage浏览器独立Dart脚本 | Linux上由distributor_preflight.py执行`dart --packages=build/packaging-tools/flutter_distributor/packages/flutter_distributor/.dart_tool/package_config.json tool/test/crisp_appimage_browser_test.dart`，先准备锁定打包工具包图 |
| Gradle/MSVC/ISCC等原生fixture | 正式workflow相应平台步骤；即使入口是.py也需要原生环境，不能视作维护机轻量测试 |
| SDK套件 | 在SDK根、准备其Flutter依赖后执行指定测试；不要套客户端hook修改器到SDK |

## 升级差异采集

正式消费者核对使用Docs的`tools/report_brand_dependencies.py`报告包/相对导入及export/part闭包，再与PATCHES、FLCLASH_ANCHORS和平台入口并集复核。底座文件反向引用品牌、原生通道、资源及构建依赖不由Dart报告穷尽；报告仍是候选，不是使用或验收证明。

当前v0.9.2输入的只读复算，在平级Docs根目录执行：

```bash
python3 tools/report_brand_dependencies.py --client ../XFlclash --changes evidence/upgrade-v0.9.2/upstream-paths.json --output evidence/upgrade-v0.9.2/brand-dependencies.json --check
```

下一次升级须换为该次固定输入及证据目录；该工具读取指定检出的工作区源码，旧版与目标版分别采集并登记HEAD/dirty范围，不能拿当前扫描冒充旧版。生成时去掉`--check`只写指定报告；详细口径见[依赖说明](https://github.com/wvjh3z/proxy-suite-docs/blob/main/evidence/upgrade-v0.9.2/DEPENDENCY_CONFIG_REACHABILITY.md)。下方Git脚本负责冻结差异和重叠路径，其中直接package导入只是快速预览，不能替代完整报告及接缝核查。

以下为只读Git示例，输出写入本次已选证据目录；变量必须由实际固定提交及授权目录提供，不可照抄占位值。`OLD_BRAND`是升级前**已提交**品牌快照；未提交改动另归档差异及摘要，不能把两种口径混成一个重叠数。

```bash
: "${OLD_UPSTREAM:?需实际提交}" "${NEW_UPSTREAM:?需实际提交}"
: "${OLD_BRAND:?需升级前品牌提交}" "${EVIDENCE_DIR:?需本次证据目录}"
export OLD_UPSTREAM NEW_UPSTREAM OLD_BRAND EVIDENCE_DIR
python3 - <<'UPGRADE_AUDIT'
import json, os, re, subprocess
from pathlib import Path
out=Path(os.environ['EVIDENCE_DIR']); out.mkdir(parents=True, exist_ok=True)
def git(*args): return subprocess.check_output(['git',*args])
old,new,brand=(os.environ[k] for k in ('OLD_UPSTREAM','NEW_UPSTREAM','OLD_BRAND'))
for ref in (old,new,brand): git('cat-file','-e',ref+'^{commit}')
diff_flags=['--no-ext-diff','--no-textconv','--find-renames=50%','-l0']
def changed(a,b): return set(filter(None,git('diff',*diff_flags,'--name-only','-z',a,b).decode().split('\0')))
up=changed(old,new); fork=changed(old,brand)
imports={}
for path in filter(None,git('ls-tree','-r','--name-only','-z',brand,'lib/xboard').decode().split('\0')):
    if not path.endswith('.dart'): continue
    text=git('show',brand+':'+path).decode()
    for module in re.findall(r"(?:import|export)\s+['\"]package:fl_clash/([^'\"]+)",text):
        target='lib/'+module
        if not target.startswith('lib/xboard/'): imports.setdefault(target,[]).append(path)
result={'old_upstream':old,'new_upstream':new,'old_brand':brand,'git_diff_flags':diff_flags,
        'upstream_paths':sorted(up),'overlap_paths':sorted(up & fork),
        'direct_imports':imports,'direct_import_changed_paths':sorted(up & set(imports)),
        'limitation':'Only direct Dart package imports; exports, relative imports, native code, resources and new modules require manual review.'}
(out/'diff-inputs.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
(out/'upstream-name-status.txt').write_bytes(git('diff',*diff_flags,'--name-status',old,new))
UPGRADE_AUDIT
```

统计固定重命名阈值50%且不限重命名候选数，禁用外部diff/textconv；name-only以重命名后的路径计数，旧路径保存在name-status。导入扫描是源码文本匹配而非Dart AST，可能包含注释示例，须人工确认。消费者筛选是快速定位而非完成审计：聚合providers导出、相对导入、原生通道、构建脚本、数据库及新增模块继续按基线F/P/S核对，不能丢弃剩余上游路径。

## 合并升级成果到 main

仅在用户明确授权合并、且ACCEPTANCE的合并门槛满足后执行；不自动派发构建。以下步骤不授权清理未知工作区或改变远端默认分支。

1. fetch三仓源/目标，记录HEAD、工作区差异、远端default_branch及分支保护；未知并发提交先核对。default_branch由GitHub仓库API只读确认，不能从origin/HEAD缓存推定。
2. 合并保留两边提交历史及独立变更。每品牌编号文件取两边合法值的较大者，保留用户更大编号；这只避免回退，不代表已实现跨分支唯一预留（REL-01）。
3. SDK/Docs先通过本任务检查并提交推送，客户端再固定真实sdk_ref/docs_ref。当前操作导航改指main，历史批次引用保留原身份；核对链接、引用可取得性及无凭据入Git。远端默认分支若不是main，报告差异并按单独授权处理，不静默更改。
4. 用户允许时推送main，确认远端SHA/祖先关系；不force覆盖已发布历史，不擅删升级分支。合并提交不等于新安装包已验证。
5. 本机active三仓保持唯一开发入口。若旧历史worktree占用main，在确认无其他任务使用且保存HEAD/差异摘要后，仅在原HEAD detach解除占用；比对差异未变，再将active切到main。其他机器没有此占用时跳过，不能机械改所有检出。
6. 按AGENTS各自声明同步安装副本：根工作区与Xboard入口分别对维护源做字节比对，客户端/SDK仓内AGENTS直接随仓维护；不覆盖其他未确认的本地差异。收尾核对三仓分支、pin、两品牌编号、工作区状态、默认分支和同步结果，记录STATUS。

## 发布编号跨分支核对

这是REL-01自动化前的人工检查，需发布任务授权；只读核对本身不授权取号、写回、构建或改AppVersion。按品牌分别建立已使用编号集合，产品build与Android versionCode分别记录。

1. 在已授权访问的客户端仓库读取`git branch -r`和远端分支列表，确认是否过期；更新远端跟踪引用须保留本地差异。对各发布分支用`git show <远端引用>:scripts/build_number.brand_a.txt`或brand_b读取计数文件（占位符须替换）；先核对脚本语义，文件是下一编号候选，不是完整使用历史。
2. 按ACCESS的Actions GET入口分页读取相关工作流历史，以真实run_id核对分支、品牌、产品build、源码和发布结果。包含升级分支与main；对取消/失败但已创建Release或Sentry release的批次也记录占用可能，未知则不直接重用。
3. 核对已有Release/草稿标签、资产来源和发布报告。tag及文件名可能仅含产品版本而不含build，草稿也可能被覆盖；不能仅看当前列表断言历史编号未使用。结合历史证据、用户交付包和Sentry release身份处理冲突。
4. 在已授权的只读后台访问范围内核对AppVersion发布配置或guest接口结果；guest只暴露当前启用目标，不是完整历史。无访问权时列出缺项，由部署维护者确认，不从客户端缓存替代后台事实。
5. 候选需高于同品牌所有已确认使用编号，且不与其他发布分支同时分配。正式派发前再核对一次；没有全局预留时采用人工串行协调。发现未知历史、并发任务或重复编号则阻止发布结论并记录REL-01；不要自动修改任何分支编号。

#132/#146重复的品牌B/build35是已知历史冲突，不通过文档改名、修改现有包或合并取max消除；后续新包用经确认的唯一编号，旧批次保留真实身份。检查记录只保存品牌、编号、分支/run和来源，不恢复安装包hash记录要求。

## 品牌底座依赖报告（只读）

升级与共享配置审查先查[依赖、配置和可达性清单](https://github.com/wvjh3z/proxy-suite-docs/blob/main/evidence/upgrade-v0.9.2/DEPENDENCY_CONFIG_REACHABILITY.md)。按其中命令在Docs执行Python报告或--check，只读客户端已追踪Dart源码，不调用Flutter、不创建原生资产、不改变check_seam_imports禁止范围。源码或导入变化后重新生成并审阅差异；候选导出闭包不是实际调用证明，具体字段/平台副作用继续人工核对。
