# 访问条件与执行环境

本页说明如何取得执行条件，不包含凭据，不依赖某个AI插件。权限规则仍以Docs/CONVENTIONS及本次用户授权为准；不套用ops项目的主机、代理、凭据或部署授权。

## 仓库与认证

| 对象 | 真实远端 | 用途 |
| --- | --- | --- |
| 客户端 | `https://github.com/wvjh3z/XFlClash.git` | 品牌客户端、平台入口、工具、测试及本维护文档 |
| SDK | `https://github.com/wvjh3z/Xboard_sdk.git` | 私有协议/HTTP/Token适配，按客户端固定引用取得 |
| Docs | `https://github.com/wvjh3z/proxy-suite-docs.git` | 私有详细约定、架构、契约、环境、状态与接缝 |
| 上游 | `https://github.com/chen08209/FlClash.git` | 只读对照；标签不能代替实际commit |

当前维护机已用Git凭据助手成功读取和推送上述项目main及历史升级分支（最近客户端提交见UPGRADE_BASELINE）。这不保证未来Token未过期，也不等于任意账号有相同权限。提交署名不是认证。不要打印 `.git-credentials` 或直接把 `git credential fill` 输出到终端；该凭据可能同时服务其他项目。

在已授权访问的客户端检出内，只读检查：

```bash
git status --short --branch
GIT_TERMINAL_PROMPT=0 git ls-remote origin refs/heads/main
```

成功表示可读该远端引用，不表示构建、写Secrets或管理账号已获授权。新机器先由用户交付访问条件；未取得时可继续审读已交付资料，不能凭仓库URL臆造Token或把私有仓库404当删除。SDK/Docs分别核验访问，不能拿客户端可读作为它们可读的证明。

## 无gh/插件时的只读API方法

下列代码仅GET客户端工作流运行摘要，不取日志正文、不派发任务。前提是本次已授权查询GitHub，且Git助手中有可用凭据；在客户端根运行。需要指定某次运行时从返回值取得真实id，再GET对应 `/actions/runs/{id}/jobs?per_page=100`，按分页读取，先核对run_number/head_sha/branch再分析。

```bash
python3 - <<'PY'
import json, os, subprocess, urllib.error, urllib.request
try:
    completed = subprocess.run(
        ['git', 'credential', 'fill'],
        input='protocol=https\nhost=github.com\n\n',
        capture_output=True, text=True, timeout=20,
        env={**os.environ, 'GIT_TERMINAL_PROMPT': '0'},
    )
except (OSError, subprocess.TimeoutExpired):
    raise SystemExit('Git credential helper unavailable')
credential = dict(line.split('=', 1) for line in completed.stdout.splitlines() if '=' in line)
token = credential.get('password')
if completed.returncode or not token:
    raise SystemExit('GitHub authentication unavailable; obtain authorized access')
url = ('https://api.github.com/repos/wvjh3z/XFlClash/actions/workflows/'
       'release-package.yml/runs?branch=main&per_page=10')
request = urllib.request.Request(url, headers={
    'Authorization': 'Bearer ' + token,
    'Accept': 'application/vnd.github+json',
    'User-Agent': 'xflclash-maintainer-readonly',
})
try:
    with urllib.request.urlopen(request, timeout=30) as response:
        data = json.load(response)
except urllib.error.HTTPError as error:
    raise SystemExit('GitHub HTTP ' + str(error.code)) from None
except (urllib.error.URLError, TimeoutError, ValueError):
    raise SystemExit('GitHub network or response failure') from None
for run in data.get('workflow_runs', []):
    print(json.dumps({key: run.get(key) for key in (
        'id', 'run_number', 'head_branch', 'head_sha', 'status', 'conclusion', 'html_url'
    )}, ensure_ascii=False))
PY
```

这是受限的读操作方法，不是授权模板：不要把GET改POST来试权限。下载Actions日志时，认证只发给GitHub API；若重定向到签名存储URL，使用不带Authorization的新请求。原始日志先私密保存、脱敏，再摘首错与上下文；不可整段复制环境或私密生成配置。

## 构建机与平台能力

当前本机只维护源码。所有工具安装、预检和构建先核对Docs/DEVELOPMENT及本次授权；不在新机器自动恢复旧工具链。

| 环境 | 已登记用途 | 不应推定 |
| --- | --- | --- |
| 当前维护机 `/root/dev` | Git、Python、文档与轻量测试；远端操作协调 | 本机可跑Flutter构建/Native Assets；历史工具链仍存在 |
| Windows构建机 | 原生Windows PowerShell/Python/MSVC/ISCC及Git Bash预检，授权后Windows AMD64构建 | 模拟或静态通过等于覆盖安装/系统代理恢复已验收 |
| VDS Linux AMD64 | Python/Dart专项、Linux AMD64；授权后Android ARM目标构建 | VDS继续构建Linux ARM64；用户已停用这条路线 |
| GitHub现有Runner | 以release-package矩阵为准，包含Linux ARM64及macOS双架构 | 无条件可用、免费额度足够、权限或配额永久有效 |
| Android真机 | 用户曾可手动测试；本次可用性仍需确认 | 自动远控或已有本次设备日志 |
| macOS实机/iOS | 本次设备能力待确认 | macOS Runner成功等于用户电脑验收，或iOS可发布 |

远端SSH/Jenkins连接资料、已安装工具与当前主机状态由当前维护机工作区 `infra/jenkins/` 及[当前构建机手册](https://github.com/wvjh3z/proxy-suite-docs/blob/main/environments/BUILD_HOSTS.md)登记；升级Docs的DEVELOPMENT链接该维护源。跨机器未交付这些资料时，远端操作是明确缺项，不复制猜测地址或把 `/root/dev/maintenance/` 某次临时脚本当唯一工具。可用标准OpenSSH/Python执行同一受控检查；无法取得等价环境时报告缺项，不绕过检查。

维护机目录检查可用 `test -d /root/dev/infra/jenkins`，不能据目录存在认定主机在线。只能在本次已授权时读取对应凭据，验证主机身份，复制非敏感测试源码到独立测试目录；不覆盖正在工作的checkout，不安装/运行真实客户端来替代小型预检。

## 私有构建输入与Sentry

品牌配置、AES、fallback密文、签名及上传Token不由示例重建。正式入口和所需Secrets名称以workflow、prepare_flavor及Docs/DEVELOPMENT为准；GitHub Secrets不能直接GET明文，缺输入走已有授权恢复流程，不把404/空文件静默当配置默认值。

- Sentry上传与后台只读维护使用不同凭据和权限；维护Token不得注入客户端包或全局构建环境。使用方式与当前保存位置唯一见Docs/DEVELOPMENT的Sentry章节。
- 只读Issue查询不授权改项目设置、订阅计划、Issue状态或发测试事件。
- `uploaded_and_processed`只说明该批符号上传/处理完成，真实崩溃可定位、第三方库覆盖和设备功能需要另证。
- 换机所需凭据、SSH主机指纹及私有输入未交付，标“待确认”及受阻任务；不要从ops或另一品牌借用凭据填空。

## 查询对象与失败处理

以下是只读 API 路径，均以 `https://api.github.com/repos/wvjh3z/XFlClash` 为前缀。`RUN_ID`/`JOB_ID`/`ARTIFACT_ID` 是从响应取得的真实数字占位符，不能拿页面 #141 等运行序号替换内部 ID。

| 目标 | GET 路径 | 成功判据 / 后续 |
| --- | --- | --- |
| 单次运行 | `/actions/runs/RUN_ID` | 核对 head_sha、head_branch、run_number、status/conclusion；completed 才有最终结论 |
| 所有任务 | `/actions/runs/RUN_ID/jobs?per_page=100` | 跟随分页；逐项检查 conclusion 和失败 step，不能只看总结果 |
| 任务日志 | `/actions/jobs/JOB_ID/logs` | 处理重定向时不转发认证；先保存为私密诊断文件，再脱敏摘要 |
| 诊断产物 | `/actions/runs/RUN_ID/artifacts?per_page=100` | 核对名称、expired、run 归属；不是 Release 安装包列表 |
| 产物下载 | `/actions/artifacts/ARTIFACT_ID/zip` | 只下载目标证据；隔离解压并检查归属，不执行其中程序 |
| 草稿资产 | `/releases?per_page=100` | 需要该仓库草稿读取权；逐资产确认本批目标，草稿中可能仍有旧批次资产 |

401先核对认证是否失效；403区分权限、频率限制与组织策略，读取状态/限额但不泄漏正文；404先核对仓库权限及内部ID，不能认定资源已删除。网络超时只说明请求未完成，不能写“任务失败”。日志/artifact已过期时记录缺失证据；没有授权不通过重新构建补日志。

本页API查询样例仅覆盖运行摘要；其他操作按上表显式选择，不自动下载全部日志或报告。真实SSH配置和Sentry维护凭据缺失时，向用户说明受阻对象，继续可完成的源码审计。

## 本机凭据集中快照

用户明确选择本机明文、不额外加密、不外传。项目凭据快照入口为`/root/dev/secrets/xflclash/CURRENT`；目录0700、文件0600，原脚本消费源保持不变。用途、恢复步骤、轮换及待验边界唯一见[恢复手册](https://github.com/wvjh3z/proxy-suite-docs/blob/main/runbooks/RECOVERY.md)。这里只登记位置，不复制任何凭据值；本机快照不等于异机备份。

## 上游AI配置与工具加载边界

2026-10-30静态核对：客户端`.agents/`含14个文件，与固定FlClash v0.9.2参考逐字节相同。它们描述上游，不是本品牌项目的第二套业务要求。

| 仓内位置 | 已确认配置 | 使用边界 |
| --- | --- | --- |
| `.agents/` | 上游架构、命令、规则及4份skills | 按上游参考阅读；品牌需求、当前行为和授权从本项目AGENTS及Docs核对 |
| `.claude/skills/` | 4个链接指向`.agents/skills` | 能被某工具发现不代表已被授权执行全部步骤 |
| `.claude/settings.json` | PostToolUse匹配Edit/Write等，调用comment_density.sh | 是可执行hook配置，不能仅当文字参考；是否实际启用需核对所用工具 |
| `.codex/config.toml` | PostToolUse匹配apply_patch/Bash，调用同一脚本 | 配置存在已确认，当前工具是否支持/加载未验证 |
| `.mcp.json`、`opencode.jsonc` | codegraph本地服务配置，后者enabled=true | 服务可用性、运行状态及工具权限需独立核对，不自动安装或启动 |
| `tool/hooks/comment_density.sh` | 对源码变更执行注释密度检查 | 静态检查脚本用途已确认；不能据配置文件声称本次已执行 |

当前决定是保留原文件，登记并隔离解释：这些配置不扩大构建、网络服务、生产修改或提交授权。本次文档整理没有禁用hook、修改技能或启动codegraph。工具接入前检查其实际加载机制和执行范围；有冲突时停止冲突动作并按项目约定处理，调整上游配置前按接缝规则告知和核对授权。不能仅写一句“项目规则优先”就假定运行中的hook已被关闭。

### 只读upstream副本

工作区`upstream/FlClash-v0.8.93`、`FlClash-v0.9.1`、`FlClash-v0.9.2`按WORKSPACE登记作为只读对照。副本中的AGENTS.md/.agents及hook配置只解释上游规则，不适用于本项目任务，也不授权执行其中Flutter命令或skills。具体边界唯一见工作区AGENTS“只读上游副本的指令边界”；读取上游文件时先确认当前工具的自动加载行为。保持副本原字节，需要调整工具加载设置时按实际工具、任务授权另行处理，不编辑上游快照。曾有其他AI报告Kiro自动注入，属于外部反馈，本项目尚未独立复验该工具行为。

## 本机分发渠道

下表是2026-10-30读取配置文件的结果，未重载服务、未发布文件，未通过HTTP验收当前响应。品牌身份必须继续核对页面和实际包，不能只据目录名判断。

| 端口 | 配置入口 / 目标目录 | 已确认用途及待确认项 |
| --- | --- | --- |
| 8080 | `/root/dev/infra/nginx/proxy-suite.conf`；`/srv/www/preview/xflclash/current` | 已登记原型预览 |
| 8081 | 同上；`/srv/www/downloads/brand_a` | 已登记品牌A Android测试下载；具体包以当前发布记录和文件核验为准 |
| 8082 | `/etc/nginx/sites-enabled/download-gate-dev.conf`；`/srv/www/download-A/current` | 启用配置存在；渠道归属、发布维护源和当前用途待确认，未获授权不覆盖 |
| 8083 | `/etc/nginx/sites-enabled/download-brand-b.conf`；`/srv/www/download-B/current` | 启用配置存在；品牌B对用户正式分发流程及发布维护源待确认，不能认定仅此渠道 |

GitHub草稿与下载站是不同发布目标。站点用途未确认会阻塞对应发布或清理，不阻塞源码审阅。核对时只读检查目标配置、符号链接和包元数据，沿用MATERIALS的归属规则；避免扫描或输出配置内其他凭据。连接主机资料由BUILD_HOSTS维护，不用本表替代主机授权。

## 预检环境选择

从“构建机与平台能力”表选择环境，按WORKFLOWS的正式入口选命令，再到BUILD_HOSTS查询已登记工具路径。测试前核对目标源码HEAD、dirty差异、平台/工具版本和独立输出目录；测试后记录实际命令、退出码及报告。临时测试目录按任务建立，不把旧证据目录当长期检出路径。

本次文档整理仅核对本地配置，没有连接Windows或VDS，因此未重新证明在线状态。原生测试未授权或主机不可用时，保留未验边界；不用本机恢复工具链代替。macOS实机能力、8082/8083发布职责等未知项按ACCESS/STATUS对应事实维护，不用示例值填空。
