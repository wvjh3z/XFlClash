# XFlclash 项目维护入口

本入口面向没有历史聊天的新维护者：ChatGPT、Gemini、Grok、Claude、DeepSeek、其他AI及人工使用同一套资料。技能、插件和会话记忆是可选辅助，不承担唯一操作步骤。**文档以能否支持实际完成授权工作验收，不以篇幅或链接数量验收。**

## 首次接手

依次阅读[HANDOVER](maintainers/HANDOVER.md) → [当前基线和功能对照](maintainers/UPGRADE_BASELINE.md) → [项目约定](https://github.com/wvjh3z/proxy-suite-docs/blob/upgrade/flclash-v0.9.2/CONVENTIONS.md) → 本次任务手册。没有明确权限/目标的关键歧义先确认；已授权的常规实施自行完成。不要先执行历史构建命令。

| 任务 | 直接入口 |
| --- | --- |
| 判断任务是否完成、哪些证据必须具备 | [统一验收](maintainers/ACCEPTANCE.md) |
| 临时文件、测试、证据和恢复材料放哪里 | [材料归档](maintainers/MATERIALS.md) |
| 当前目录职责、旧路径和迁移规则 | [工作区路径](maintainers/WORKSPACE.md) |
| 识别工作区、分支、仓库及执行权限 | [零上下文接手](maintainers/HANDOVER.md) |
| 了解品牌功能由哪层负责、下次升级检查什么 | [升级对照基线](maintainers/UPGRADE_BASELINE.md) |
| 升级FlClash、SDK或原生插件 | [三个原则与升级流程](maintainers/UPGRADING.md) |
| 改代码、查日志、跑检查、提交或构建 | [维护流程](maintainers/WORKFLOWS.md) |
| GitHub/远端主机/Sentry访问条件 | [访问与环境](maintainers/ACCESS.md) |
| 配置由谁覆盖、何时生效 | [配置来源](https://github.com/wvjh3z/proxy-suite-docs/blob/upgrade/flclash-v0.9.2/CONTRACTS.md#配置来源与生效顺序) |
| 支持平台、系统门槛及未验范围 | [兼容范围](maintainers/UPGRADE_BASELINE.md#平台兼容与支持范围) |
| 登录、节点、数据库、更新或客服故障 | [故障定位](https://github.com/wvjh3z/proxy-suite-docs/blob/upgrade/flclash-v0.9.2/runbooks/TROUBLESHOOTING.md#客户端业务故障定位入口) |
| 构建失败 | [版本化失败经验](build-failures/README.md) |
| 查已找到的成品、符号证据及恢复缺口 | [实际材料索引](https://github.com/wvjh3z/proxy-suite-docs/blob/upgrade/flclash-v0.9.2/evidence/material-inventory-20261029/README.md) |
| 查当前未关闭问题、成品及设备验收 | [Docs/STATUS当前快照](https://github.com/wvjh3z/proxy-suite-docs/blob/upgrade/flclash-v0.9.2/STATUS.md#当前接手快照2026-10-29) |

## 谁维护哪类事实

| 唯一维护位置 | 内容 | 不应承担 |
| --- | --- | --- |
| 本目录ACCEPTANCE / MATERIALS | 任务通过条件、证据层级、材料归属及交接规则 | 复制各专项操作流程或声明实际验收结果 |
| 本目录HANDOVER / ACCESS / WORKFLOWS | 跨AI接手与任务入口、权限判断、验证方法 | 复制私密配置、每次构建流水账 |
| 本目录UPGRADING / UPGRADE_BASELINE | 三个原则、功能归属、升级逐项对照 | 替代机器接缝白名单或设备验收 |
| 本目录build-failures | 按底座版本归档的失败、修复、预防经验 | 把历史工具版本当当前构建环境 |
| Docs/CONVENTIONS | 跨仓开发规则与用户决定 | 另一套升级原则正文 |
| Docs/ARCHITECTURE、CONTRACTS | 详细调用链、字段/接口/失败语义 | 操作环境和发布完成声明 |
| Docs/DEVELOPMENT | 共享开发流程及专项手册导航 | 重复维护已经拆出的专项正文 |
| Docs/runbooks | 环境、构建发布、监测、设备验收及故障恢复的详细步骤 | 代替本次授权或实际验收结果 |
| Docs/STATUS | 当前能力、已确认缺口、实际验收及历史证据 | 将旧记录顶部当作当前全量状态 |
| Docs/PATCHES、FLCLASH_ANCHORS | 接缝登记与机器定位 | 将锚点数误称逻辑接缝数 |
| 源码及固定配置 | 可执行事实、依赖锁定、品牌身份 | 擅自覆盖用户明确的产品决定 |

本机可离线读取平级 `../Docs/` 和 `../Xboard_sdk/`。这两者是独立私有仓库，不能因为客户端可以访问就假设访问条件齐全。Docs旧构建复盘文件只保留导航，历史正文已归本仓库。

## 证据用语

- **用户已确认**：带决定及适用范围；不是对所有未来生产操作的授权。
- **当前源码事实**：关联实际提交和调用者，不仅引用注释。
- **已验证**：注明静态/受控测试/原生主机/正式包/设备及目标；这几个层级不能互相替代。
- **推断**：说明依据及尚缺证据，不写成根因。
- **待确认**：写清缺什么、影响什么、如何继续取得。
- **历史**：保留当时版本/提交/平台和结果，不覆盖较新的决定。

信息冲突时核对代码、配置、运行证据和用户决定，修正负责该信息的文档；无结论就保留冲突及影响。禁止用示例值替代真实环境事实。收尾验证清单见HANDOVER。
