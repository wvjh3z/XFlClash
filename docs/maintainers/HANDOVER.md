# 零上下文接手

本页是首次接手的必读摘要。读完后按[任务导航](../README.md#首次接手)打开相关章节，无需通读ARCHITECTURE、CONTRACTS、DEVELOPMENT或全部行为表。所有AI和人工使用同一入口；访问私有资料受阻时报告具体缺项。

## 产品和当前目标

这是基于FlClash v0.9.2的Xboard商业客户端：品牌A为OmoFly，品牌B为袋鼠加速。两品牌共用业务实现，面向Android、Windows、macOS、Linux；“形态A”是当前产品界面，和“品牌A/B”是不同概念。没有应用级iOS发行目标。

当前客户端、SDK、Docs维护分支均为main。按[工作区](WORKSPACE.md)取得三个平级仓库；本机入口为`/root/dev/workspace/proxy-suite/active/`下的`XFlclash`、`Xboard_sdk`、`Docs`。实际HEAD和CI固定引用从Git及workflow读取，不在本页复制滚动提交号。

- 客户端：`wvjh3z/XFlClash`，业务、适配、原生入口、测试和维护导航。
- SDK：`wvjh3z/Xboard_sdk`，私有协议、认证、HTTP和面板适配。
- Docs：`wvjh3z/proxy-suite-docs`，私有规则、架构、契约、状态和证据。

## 最小规则入口

硬规则按[CONVENTIONS的RUL索引](https://github.com/wvjh3z/proxy-suite-docs/blob/main/CONVENTIONS.md#硬规则索引)定位原文，本页只保留执行提示：

1. 先确认目标和Git状态，保留已有差异（RUL-01）。
2. 客户端、SDK和插件可维护，Xboard主程序只读（RUL-02）。
3. 本机仅源码、文档和轻量检查，不恢复工具链或隐式构建（RUL-03）。
4. 构建、推送、发布和合并按任务授权；已有授权不重复确认（RUL-04）。
5. 接缝变更先告知；新增接缝/依赖核对授权（RUL-05）。
6. 升级按三原则：复用能力核行为、自有逻辑保留、未用功能检查间接影响（RUL-06）。
7. 凭据只在受限资料中使用，不回显、不入Git（RUL-07）。
8. 区分要求、实现、证据和待确认；事实只在负责文档维护（RUL-08）。
9. 失败经验归档，测试和恢复材料按用途保留（RUL-09）。

## 当前状态从哪里判断

先看[当前交付表](https://github.com/wvjh3z/proxy-suite-docs/blob/main/STATUS.md#当前交付与设备验收概览)和[当前缺口索引](https://github.com/wvjh3z/proxy-suite-docs/blob/main/STATUS.md#当前缺口索引)。成功构建批次、设备验收和修复源码分别列证据，不在本页复制结果清单。

涉及发布时还需读[发布待办](https://github.com/wvjh3z/proxy-suite-docs/blob/main/STATUS.md#基线局部缺口与发布待办)：全局构建编号、最终APK验签以及设备/恢复材料缺口以该表为准。历史缺陷先复核，不能据旧记录直接宣布仍然复现或已经修复。

## 选择执行环境

本机可做Git只读检查、Python文档/工具轻量检查；Windows原生预检去Windows构建机，Linux AMD64及Android专项去VDS。Linux ARM64和macOS原生环境按GitHub授权处理，不恢复已退役的VDS Linux ARM64构建路线。主机当前在线和工具完整性需当次核验，详见[环境能力](ACCESS.md#构建机与平台能力)。

先执行下方只读仓库核对，再按[WORKFLOWS](WORKFLOWS.md)选择检查。远端连接、当前授权和工具准备见[ACCESS](ACCESS.md)，不从历史任务目录复制命令直接出包。文档入口不需要任何AI专有插件；仓内上游AI配置的清单与边界见[说明](ACCESS.md#上游ai配置与工具加载边界)。

## 1. 识别当前目录和Git状态

在已经取得的客户端仓库执行以下只读命令：

```bash
pwd
git status --short --branch
git remote get-url origin
git rev-parse HEAD
git branch --show-current
git submodule status
```

客户端远端应为 `https://github.com/wvjh3z/XFlClash.git`。检查平级Docs及SDK各自的status、origin和HEAD，不从客户端提交推断它们一致。本机当前目录与基线见[对照基线](UPGRADE_BASELINE.md)；磁盘目录名可能旧于实际分支。

保留已有修改、未跟踪文件和dirty子模块，不用reset/clean初始化“干净环境”。当前Core CA临时差异有历史登记，不纳入普通客户端提交；实际差异仍须检查。若当前仓库/分支与目标不同，先查是否另有已存在的正确检出，不在有未知改动的目录直接切分支。

新机器需先取得三仓访问权，保持 `XFlclash/`、`Xboard_sdk/`、`Docs/` 平级布局；SDK path依赖是 `../Xboard_sdk`。只拿到文档不代表拥有品牌密钥、签名、Sentry上传或远端主机授权，缺项按ACCESS处理。

## 2. 确定执行范围

从用户任务确认品牌、平台、分支及允许动作，按[项目约定](https://github.com/wvjh3z/proxy-suite-docs/blob/main/CONVENTIONS.md)判断权限；实际环境能力见[ACCESS](ACCESS.md#构建机与平台能力)。代码、测试、构建、发布和生产变更是不同范围，未知关键前提先确认。本机只做源码与轻量检查，不恢复构建工具链。

## 3. 跟到真实消费者

从[功能对照表](UPGRADE_BASELINE.md)选择本次ID，沿页面/生命周期入口 → 适配器/provider → SDK或底座 → 原生实现追踪。检查实际默认值、返回值、失败/取消、旧会话结果、文件/数据库副作用，而非只搜索函数是否存在。

同一功能可横跨自有与复用层。当前品牌行为和上游默认不一致时，先找已确认决定；不能为了消除diff直接恢复上游。所有平台的“显示相同”不代表系统路由、服务、安装和退出一致。

## 4. 用证据验收文档是否可接手

不要求为了验收文档真实构建或操作线上。使用本次授权内的只读定位、离线检查和已有证据完成下列演练；缺资料就补维护源或记录阻塞，不编造通过：

| 演练 | 合格标准 |
| --- | --- |
| 找到正确源码 | 能报告客户端/SDK/Docs实际HEAD、活跃分支和未提交差异；不会误用旧目录名 |
| 解释一项品牌规则 | 从对照ID找到生产入口、底座边界、测试以及用户决定，无需翻聊天 |
| 选择检查 | 能区分本机轻量检查、远端预检、正式构建、设备验收，并选对入口 |
| 查询一次构建 | 能凭真实run号/源码查到失败步骤或明确缺认证；不重跑、不泄漏凭据 |
| 准备提交 | 能确定各仓改动、Docs/SDK固定引用和不会自动触发客户端构建的事实 |
| 升级准备 | 能按三原则逐项分类，列接缝和平台缺口，而非只复制上游更新清单 |

## 5. 收尾

按[统一验收](ACCEPTANCE.md#完成状态与收尾)说明实际通过层级、缺口和下一步，按[材料规则](MATERIALS.md)归档；执行检查见[WORKFLOWS](WORKFLOWS.md)。本页不再重复这些规则。
