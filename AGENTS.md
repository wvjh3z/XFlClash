# XFlclash 协作说明

任务收尾按[统一验收标准](https://github.com/wvjh3z/XFlClash/blob/main/docs/maintainers/ACCEPTANCE.md)及[材料归档规则](https://github.com/wvjh3z/XFlClash/blob/main/docs/maintainers/MATERIALS.md)检查；正式交接不得依赖被忽略的临时文件，清理先核对其他任务使用情况。

XFlclash 是 FlClash fork，形态 A 商业客户端在 `lib/xboard/` 中维护；底座继续承担内核、VPN、代理、Profile 和平台集成。

## 开始工作

先读[跨 AI 维护入口](docs/README.md)和[零上下文接手](docs/maintainers/HANDOVER.md)。这些资料适用于人工及所有 AI 提供商；文档合格以支持授权任务实际完成为准，不以篇幅或链接检查通过代替。

先读 [统一约定](https://github.com/wvjh3z/proxy-suite-docs/blob/main/CONVENTIONS.md)、[当前架构](https://github.com/wvjh3z/proxy-suite-docs/blob/main/ARCHITECTURE.md) 与本任务涉及的 [契约](https://github.com/wvjh3z/proxy-suite-docs/blob/main/CONTRACTS.md)。环境、生成、测试、构建和同步流程见 [DEVELOPMENT](https://github.com/wvjh3z/proxy-suite-docs/blob/main/DEVELOPMENT.md)，基线和未关闭问题见 [STATUS](https://github.com/wvjh3z/proxy-suite-docs/blob/main/STATUS.md)。

当前 Docs 仓库 `wvjh3z/proxy-suite-docs` 和 SDK 仓库 `wvjh3z/Xboard_sdk` 为私有仓库，需要 GitHub 授权；未授权时可能显示 404。本地将 Docs checkout 为 `../Docs`、SDK checkout 为 `../Xboard_sdk`，保留工具和 path 依赖所需的平级布局。当前维护 main，已合入 FlClash v0.9.2 品牌适配；upgrade/flclash-v0.9.2 保留历史，实际完成/待迁移范围以 sibling Docs/STATUS 为准；不沿用旧版构建命令推断新发行链已就绪。

当前 DEVELOPMENT 已承接执行细节，不需要读取旧 AGENTS 快照或旧 spec；不要沿用旧 IPC、Manager 或 Flutter 固定值。

升级实施后及交付前，必须执行 [三原则升级流程](docs/maintainers/UPGRADING.md)及[品牌行为基线](docs/maintainers/UPGRADE_BASELINE.md)，对照本项目旧版品牌A/B的实际行为，覆盖未改动但依赖旧底座语义的代码；源码差异、验证和待验收不能由构建通过替代。

## 改动边界

- 可修改代码包括本客户端、SDK 和 Xboard 插件；Xboard 主程序保持只读。协议兼容在 SDK 处理，服务端扩展通过插件实现，不修改主程序 Controller、Service、路由或插件加载框架。
- Xboard 新业务放 `lib/xboard/`；Tab 对底座的复用通过 `shell/adapters/`，不在页面复制底座内核逻辑。
- 面板协议、HTTP 和 Token 适配优先修 SDK，客户端用 XboardService 与 XbResult。
- 既有 FlClash 文件改动按 [PATCHES](https://github.com/wvjh3z/proxy-suite-docs/blob/main/PATCHES.md) 实际授权登记，维护 [anchors](https://github.com/wvjh3z/proxy-suite-docs/blob/main/FLCLASH_ANCHORS.md)。不从历史“11 处”数字推断白名单。
- 新接缝/依赖先核对当前任务授权；尚未授权时说明必要性后取得决策。
- 生成物不手改。真实 flavor、AES、签名和 Token 不回显或提交，既有证书策略见 SECURITY.md。

## 校验入口

以下是授权测试主机的入口；本机 `/root/dev` 不恢复工具链或运行隐式原生编译。轻量检查见[维护流程](docs/maintainers/WORKFLOWS.md)。从客户端根目录执行；需先完成 SDK sibling 路径、子模块、依赖与 codegen 准备。

```bash
flutter analyze lib
flutter test test/xboard/ test/sdk_contract_test.dart
flutter test tool/test/
dart --packages=.dart_tool/package_config.json tool/check_seam_imports.dart
dart --packages=.dart_tool/package_config.json tool/check_xb_theme_entrypoints.dart
dart --packages=.dart_tool/package_config.json tool/check-line-anchors.dart
dart --packages=.dart_tool/package_config.json tool/check-seam-whitelist.dart --baseline upstream/main
```

按改动选择必需测试；upstream/main 必须存在并代表真实上游。没有该引用时，可显式传真实上游 commit，或配置 `git config xflclash.seamBaseline <真实上游提交>` 供 pre-commit 使用；不得用当前 HEAD 冒充上游。本次 GitHub 维护的基线与验证结果见 Docs/STATUS。核心工具兼容新 Docs 和旧 `.kiro` 布局，跨布局可显式传 --anchors/--patches。

[UI_FRAMEWORK](.github/UI_FRAMEWORK.md) 与 [golden 环境](test/xboard/golden/README.md) 继续作为专项参考。fork 提交使用现有 `[xfork] type(scope): subject` hook 格式，上游同步使用 `sync(flclash): ...`；保留上游 CHANGELOG，产品变化记 CHANGELOG_XBOARD。

## 任务收尾

分析、排障、修改与验收后必须检查当前 Docs 是否覆盖本轮新事实、文档偏差、有证据的缺口及用户决策变化；有新增则应用 [xflclash-doc-sync](https://github.com/wvjh3z/proxy-suite-docs/blob/main/skills/xflclash-doc-sync/SKILL.md)，按唯一职责维护已有章节。本轮已读的技能直接复用；已覆盖结论无需追加，用户明确只读/不改文件时仅报告待同步项。检查与报告遵循当前 DEVELOPMENT，不扩大提交、构建或部署授权。

构建、打包或必需验收失败后，必须遵守 sibling Docs/CONVENTIONS.md 的“构建失败后的修复经验必须归档（硬性约定）”：查阅并更新本仓库 [docs/build-failures/README.md](docs/build-failures/README.md) 及对应底座版本的事件记录（v0.8.93/v0.9.1历史复盘也已纳入本目录），将根因、实际修复、正负控和正式入口验证边界随任务归档；未补齐经验不得宣称修复完整交付。该要求不授权触发构建或提交。
