# 工作区与文档路径

本页负责目录职责、活跃入口及兼容关系；版本/源码事实见[升级基线](UPGRADE_BASELINE.md)，执行流程见[WORKFLOWS](WORKFLOWS.md)。不再为每次底座升级创建新的长期目录。以下是本机实际布局，不是新机器必须照抄的绝对路径。

## 长期布局

```text
/root/dev/workspace/proxy-suite/
├── README.md                  本机路由入口，无独立业务事实
├── active/                    唯一活跃工作区，版本由Git分支表示
│   ├── XFlclash/              客户端仓库
│   │   └── docs/
│   │       ├── README.md      客户端唯一接手入口
│   │       ├── maintainers/   接手、访问、操作、三原则和行为对照
│   │       └── build-failures/ 按底座版本归档失败经验
│   ├── Xboard_sdk/            私有SDK仓库，满足../Xboard_sdk依赖
│   └── Docs/                  平级共享文档仓库，满足现有机器消费者
├── upstream/                  只读上游版本源码及来源登记
├── Xboard/                    外部维护后端；主程序只读，插件按授权维护
├── XFlclash/                  旧main检出及Git公共元数据，非活跃开发入口
├── Docs/                      旧main检出及Git公共元数据；历史检出，不再读取操作资料
├── Xboard_sdk -> ../../sdk    旧布局兼容
└── upgrades/                  旧目录兼容链接已退役，无活跃checkout
```

`/root/dev/sdk`同样是旧main检出和SDK公共Git元数据，不是active的SDK源。上面三个active仓库仍为Git worktree；它们的`.git`指向原主仓公共目录。**不要因旧目录名而删除、移到归档或执行git worktree prune**。原位置已有未提交差异不属于本次迁移，本次未清理。

2026-10-29完成当前消费者检查：旧版本目录两条兼容链接已删除；停用的`infra/jenkins/linux-arm64-v091/preflight_test.py`改为读取`XFLCLASH_CLIENT_ROOT`，默认active，四项轻量测试通过。另7条过期插件软链接及5份被Git忽略的生成路径输入已备份归档后移除，未改生成文件内容、未运行Flutter重生成。原始备份与清单位于`/root/dev/maintenance/xflclash/archive/20261029-retired-path-inputs/`。其他历史记录中的旧路径只解释当时环境，不可继续执行；公共Git元数据保留。

`upstream/`可以按版本保存只读对照；只有上游参考和历史证据用版本名。需要并行任务时另外创建用户授权的隔离worktree，不把临时任务目录宣称为新的唯一活跃入口。未来升级只修改分支/基线，不搬active。

## 文档各自负责什么

| 位置 | 唯一职责 |
| --- | --- |
| 客户端docs/README.md | 接手路线与负责文档索引，不复制细节 |
| 客户端docs/maintainers | 可执行的任务编排、访问前提、三原则及品牌行为映射 |
| 客户端docs/build-failures | 0.8.93、0.9.1、0.9.2等版本的失败经验；版本是记录属性 |
| 平级Docs/CONVENTIONS | 跨仓权限、产品要求、协作和证据规则；升级原则正文引用客户端UPGRADING |
| 平级Docs/ARCHITECTURE、CONTRACTS | 客户端—SDK—后端的详细调用链和数据契约，客户端只维护导航/对照不复制正文 |
| 平级Docs/DEVELOPMENT | 共享环境与详细专项操作；客户端WORKFLOWS负责编排到这些步骤 |
| 平级Docs/STATUS | 当前问题与实际验收；历史阶段不能替代当前快照 |
| 平级Docs/PATCHES、FLCLASH_ANCHORS | 唯一机器接缝数据，位置是现有工具/CI接口，不能只为美观搬走 |
| 各仓AGENTS | 该仓工作规则及入口；本机安装的/root/dev/AGENTS.md由active Docs维护源同步 |

这不是把资料分别写两遍：同一事实只改负责文档。未来只有职责真正分离且消费者已迁移，才拆详细文档；不建立另一套“最新版”全文副本。客户端docs与独立Docs的GitHub链接使用当前维护分支；合并main时按新维护策略统一更改，而非长期混用。

## 本机入口与服务边界

共享构建机操作资料已迁入active Docs的[构建机手册](https://github.com/wvjh3z/proxy-suite-docs/blob/upgrade/flclash-v0.9.2/environments/BUILD_HOSTS.md)，旧Docs不再作为任何当前操作资料来源。`infra/jenkins/`仍是脚本维护源；历史记录集中到当前Docs/history，按原日期解释。

项目skill链接应指向active/Docs/skills的维护源；安装副本/root/dev/AGENTS.md与该源字节一致。用户另有工具发现缓存时，重新加载入口；不修改其他项目的skill或规则。

8080/8081既有NGINX配置、已发布文件、凭据和构建机工作目录未随此次维护机迁移改变。旧Docs可能仍被既有预览配置引用：发布状态与编辑源分开，新编辑源是active，但迁移目录不授权重新发布或改服务。历史主机工具目录中的v091也不由本机目录重命名自动变化。

## 移动后的轻量核验与恢复

在本机执行只读核对，不运行构建：

```bash
cd /root/dev/workspace/proxy-suite/active/XFlclash
git status --short --branch
git worktree list
git -C ../Xboard_sdk status --short --branch
git -C ../Docs status --short --branch
python3 ../Docs/tools/check_docs.py
python3 -m unittest discover -s ../Docs/tools -p test_check_docs.py
cmp ../Docs/collaboration/workspace/AGENTS.md /root/dev/AGENTS.md
test ! -L /root/dev/workspace/proxy-suite/upgrades/flclash-v0.9.1
test ! -L /root/dev/workspace/proxy-suite/XFlclash-upgrade-v0.9.1
```

成功标准：三仓分支/HEAD符合任务、既有差异未丢失，worktree登记为active，旧别名已不存在，文档检查与安装副本一致。链接检查不证明远端GitHub已推送。

如目录曾被外部工具再次移动，先定位真实文件和公共Git目录、保存状态，再对三仓各运行`git worktree repair <实际路径>`；尖括号为必须替换的占位符，不能照抄。repair只修登记，不应通过reset/clean消除用户差异。恢复旧布局必须先处理兼容链接且确认目标无另一份数据，不提供可误删目录的一键回滚命令。没有明确迁移授权时只诊断。

新机器无需复制历史main检出或本机绝对路径：取得私有仓库权限后，按HANDOVER在同一目录下检出XFlclash、Xboard_sdk、Docs即可；CI同样只依赖自己的checkout和平级布局，不读取本机active或旧别名。
