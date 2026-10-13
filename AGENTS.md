# XFlclash 协作说明

XFlclash 是 FlClash fork，形态 A 商业客户端在 `lib/xboard/` 中维护；底座继续承担内核、VPN、代理、Profile 和平台集成。

## 开始工作

先读 [统一约定](https://github.com/wvjh3z/proxy-suite-docs/blob/main/CONVENTIONS.md)、[当前架构](https://github.com/wvjh3z/proxy-suite-docs/blob/main/ARCHITECTURE.md) 与本任务涉及的 [契约](https://github.com/wvjh3z/proxy-suite-docs/blob/main/CONTRACTS.md)。环境、生成、测试、构建和同步流程见 [DEVELOPMENT](https://github.com/wvjh3z/proxy-suite-docs/blob/main/DEVELOPMENT.md)，基线和未关闭问题见 [STATUS](https://github.com/wvjh3z/proxy-suite-docs/blob/main/STATUS.md)。

当前 Docs 仓库 `wvjh3z/proxy-suite-docs` 和 SDK 仓库 `wvjh3z/Xboard_sdk` 为私有仓库，需要 GitHub 授权；未授权时可能显示 404。本地将 Docs checkout 为 `../Docs`、SDK checkout 为 `../Xboard_sdk`，保留工具和 path 依赖所需的平级布局。当前底座仍为 FlClash v0.8.93。

当前 DEVELOPMENT 已承接执行细节，不需要读取旧 AGENTS 快照或旧 spec；不要沿用旧 IPC、Manager 或 Flutter 固定值。

## 改动边界

- 可修改代码包括本客户端、SDK 和 Xboard 插件；Xboard 主程序保持只读。协议兼容在 SDK 处理，服务端扩展通过插件实现，不修改主程序 Controller、Service、路由或插件加载框架。
- Xboard 新业务放 `lib/xboard/`；Tab 对底座的复用通过 `shell/adapters/`，不在页面复制底座内核逻辑。
- 面板协议、HTTP 和 Token 适配优先修 SDK，客户端用 XboardService 与 XbResult。
- 既有 FlClash 文件改动按 [PATCHES](https://github.com/wvjh3z/proxy-suite-docs/blob/main/PATCHES.md) 实际授权登记，维护 [anchors](https://github.com/wvjh3z/proxy-suite-docs/blob/main/FLCLASH_ANCHORS.md)。不从历史“11 处”数字推断白名单。
- 新接缝/依赖先核对当前任务授权；尚未授权时说明必要性后取得决策。
- 生成物不手改。真实 flavor、AES、签名和 Token 不回显或提交，既有证书策略见 SECURITY.md。

## 校验入口

从客户端根目录执行；需先完成 SDK sibling 路径、子模块、依赖与 codegen 准备。

```bash
flutter analyze lib
flutter test test/xboard/ test/sdk_contract_test.dart
flutter test tool/test/
dart run tool/check_seam_imports.dart
dart run tool/check_xb_theme_entrypoints.dart
dart run tool/check-line-anchors.dart
dart run tool/check-seam-whitelist.dart --baseline upstream/main
```

按改动选择必需测试；upstream/main 必须存在并代表真实上游。没有该引用时，可显式传真实上游 commit，或配置 `git config xflclash.seamBaseline <真实上游提交>` 供 pre-commit 使用；不得用当前 HEAD 冒充上游。本次 GitHub 维护的基线与验证结果见 Docs/STATUS。核心工具兼容新 Docs 和旧 `.kiro` 布局，跨布局可显式传 --anchors/--patches。

[UI_FRAMEWORK](.github/UI_FRAMEWORK.md) 与 [golden 环境](test/xboard/golden/README.md) 继续作为专项参考。fork 提交使用现有 `[xfork] type(scope): subject` hook 格式，上游同步使用 `sync(flclash): ...`；保留上游 CHANGELOG，产品变化记 CHANGELOG_XBOARD。
