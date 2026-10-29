<!-- docs-migration:start -->

品牌构建的目标确认、访问条件、失败处理与交付流程先见[维护流程](../docs/maintainers/WORKFLOWS.md)；当前平台和底座见[升级基线](../docs/maintainers/UPGRADE_BASELINE.md)。本文的命令不构成构建授权。
> **当前品牌构建导航。** 完整流程见 [DEVELOPMENT](https://github.com/wvjh3z/proxy-suite-docs/blob/upgrade/flclash-v0.9.2/DEVELOPMENT.md) 与 [Android release skill](https://github.com/wvjh3z/proxy-suite-docs/blob/upgrade/flclash-v0.9.2/skills/xflclash-android-release/SKILL.md)。旧构建说明已由当前 Docs 承接；Docs 为私有仓库，需要 GitHub 授权。
<!-- docs-migration:end -->

# XFlclash 品牌构建与发布入口

XFlclash 当前维护形态 A 商业客户端，本独立分支的 FlClash 底座目标为 **v0.9.2**，正式成品仍待验收。产品展示版本、底座版本、构建号及 APK 原生版本分别核对，不能用一个“版本号”代替全部发布输入。

完整流程由 [DEVELOPMENT](https://github.com/wvjh3z/proxy-suite-docs/blob/upgrade/flclash-v0.9.2/DEVELOPMENT.md#多品牌构建和版本) 和 [Android release skill](https://github.com/wvjh3z/proxy-suite-docs/blob/upgrade/flclash-v0.9.2/skills/xflclash-android-release/SKILL.md) 唯一维护。本页是客户端仓库的导航与检查摘要。Docs 仓库及 [SDK](https://github.com/wvjh3z/Xboard_sdk) 为私有仓库，需要维护者授予 GitHub 访问权限；本地分别 checkout 为客户端平级的 `Docs/` 和 `Xboard_sdk/`。

## 选择入口

| 任务 | 入口 | 用途 |
| --- | --- | --- |
| 本机 Android 品牌包 | `bash scripts/build_local.sh release arm64 brand_a` | 包装 `tool/build_android_local.py`，统一准备、构建、APK/AOT 核验和 Sentry 符号上传 |
| 本机桌面安装包 | `bash scripts/package_desktop_local.sh brand_a auto` | 在对应平台准备并打包；版本分配与限制先核对 DEVELOPMENT |
| GitHub 多平台安装包 | [Release Package](workflows/release-package.yml) | 唯一远端正式出包流程，支持单目标与组合；符号上传不受安装包 `upload` 开关跳过 |
| 模块分析、测试与接缝检查 | [Xboard CI](workflows/xboard-ci.yml) | 手动运行一套检查，不重复构建客户端 |
| Sentry 后台维护 | [Sentry maintenance](workflows/sentry-maintenance.yml) | 独立管理后台，不编译客户端 |

`tool/` 中的品牌注入、SDK checkout、原生库存、符号生成与上传工具是上述入口的依赖；Go/Rust 已迁到 `plugins/setup/hook`、`plugins/setup/setup_hooks`、`plugins/rust_api/hook` 与 Android gomobile Gradle；旧 Buildkit/Cargokit 残留已退役。`dart setup.dart <platform>` 保留为底座工具，品牌正式包使用上表入口。

旧上游发布 workflow、Telegram 脚本及配套模板已退役；旧形态 A diff 守卫并入统一接缝白名单。macOS 临时 manifest/Xcode 对照工具已从当前树删除，生产中的依赖解析、库存及受控符号探针继续保留。历史脚本可从 Git 历史追溯，不维护另一份旧入口。

## 版本与构建输入

| 值 | 当前来源与用途 |
| --- | --- |
| 产品版本 | 私密 `flavors/<brand>/flavor.yaml` 的 `versionName`，构建时注入 `XB_PRODUCT_VERSION`，用于产品关于页和文件命名 |
| 底座版本 | `pubspec.yaml` 的 FlClash 版本，通过 `--build-name` 进入 PackageInfo / Android 原生 versionName |
| 品牌构建号 | GitHub 用 `scripts/build_number.<brand>.txt`；本机 Android 用 Git 忽略的 `.local-build/build_number.<brand>.txt`。批次固定后注入 `XB_BUILD_NUMBER` 供应用内更新比较 |
| Android versionCode | `--build-number` 与 ABI 打包策略共同决定；本机单 ABI 包核对为批次构建号，split-per-abi 可能产生 ABI 偏移 |
| buildTag | 批次时间标识 `YYYYMMDDHHMM`，注入 `XB_BUILD_TAG`，用于产品关于页辨认构建 |
| ABI | Flutter target、Gradle 原生库筛选和 `XB_ANDROID_ABI` 一起核对；`XB_TARGET_ABI` 是 Gradle 输入，不是同一个 Dart 键 |

`prepare_flavor` 当前不会把 pubspec 改为 `<产品版本>+flclash<底座版本>`。应用内更新比较 `XB_BUILD_NUMBER`，Android 安装另检查原生 versionCode、包名和签名；两层都要验证。

本机 Android 首次使用时，将仓库品牌计数只读复制为本机起点；以后只读写 `.local-build/`，不修改 GitHub 计数。该目录位于 Flutter build 输出之外，普通 clean 不会清除。新 release 默认本机计数+1；失败重试沿用同一批次冻结编号，已有更高本机成功号时拒绝过期批次，不能回退覆盖。成功并完成产物核验后才推进本机计数，debug/诊断不推进；首次复制起点不表示执行过构建。CI 的计数更新时序按其 workflow 和构建记录核对，仓库中的数字不自动等于某个旧下载包的编号。最新实际 APK 和验证状态见 [STATUS](https://github.com/wvjh3z/proxy-suite-docs/blob/upgrade/flclash-v0.9.2/STATUS.md)。

GitHub Release Package 表单只提供 `flavor`、`target`、`build_number`、`upload` 四项。SDK 固定引用与默认 false 的 `verify_symbolication` 由本次源码的 `tool/release-config.json` 维护；该开关只控制额外桌面受控探针，正式符号链仍执行。

点击一次 Run workflow 即在同一条运行中完成输入归一、编号解析和所选平台打包。`build_number` 留空、未提供或 null 都按未填写处理，读取本次源码中的品牌计数；手动填写须为不小于该计数的整数（1–65535）。其他未提供的公开字段使用表单默认值，未知字段和非法值仍拒绝。仅允许 `workflow_dispatch`，不再保留准备记录、内部二次分派或父子运行关联；三个 workflow 文件保持，不接入 push、PR 或 schedule。

自动取号时，Actions 列表标题只显示品牌和目标，例如 `brand_a · windows-amd64`；手动填号时可显示 `brand_a · windows-amd64 · build 22`。实际编号继续显示在运行摘要、各平台任务名、草稿 Release 和应用内。用户已取消为了列表标题显示自动号而增加第二条运行的方案。

setup 使用本次手动触发的固定 SHA/ref 归一请求并读取 SDK/探针配置；各平台 checkout、编号工具、摘要和 Sentry 的 `source_revision` 继续使用这份源码，分支后来移动不改用新代码。重试可在该运行中进行；修改 workflow 或修复代码后应重新 Run workflow，旧记录的 Re-run 仍执行旧快照。

所有平台、安装包和 Sentry 使用同一实际编号。`upload=true` 时上传前确认目标仍为草稿，上传成功后同步标题和自动说明中的编号；已公开版本拒绝覆盖，上传失败不刷新旧编号。草稿沿用同品牌/产品版本的 tag，未选平台的旧资产仍可能保留，标题表示本轮上传编号，不能由此推断所有历史资产同号。`upload=true` 且全部目标成功后，下一计数取最新 main 值与实际编号+1的最大值；`upload=false` 不推进。GitHub 编号按用户决策维护，本机开发计数独立；并发 GitHub run 或旧源码重跑仍需核对，未实现全局唯一取号。开发包编号较高的测试设备不会把较低编号的正式包识别为更新，文件隔离不改变更新比较或签名规则。

## 品牌配置与签名

- Windows 安装器发布者与可选官网/支持/更新网页由公开 `flavors/<brand>/windows_installer.yaml` 维护：A 为 Omofly，B 为 Daishu；三个网址可全部不填，未配置不生成链接。现有桌面注入入口读取该文件，无需更新品牌 Secrets。字段与离线检查见 [Windows 安装器公开信息](https://github.com/wvjh3z/proxy-suite-docs/blob/upgrade/flclash-v0.9.2/DEVELOPMENT.md#windows-安装器公开信息)。
- 系统图标由公开 `flavors/<brand>/system_icons/` 维护：Windows/Linux 三态品牌托盘、macOS 单色 template、Android 单色通知/磁贴。桌面入口显式传 `--platform` 校验并复制预生成资源；Android 使用品牌 sourceSet，正式构建不运行图像生成器或浏览器。资源维护与验收见 [品牌系统图标](https://github.com/wvjh3z/proxy-suite-docs/blob/upgrade/flclash-v0.9.2/DEVELOPMENT.md#品牌托盘与-android-系统图标)。
- 真实 `flavor.yaml`、`fallback.bin`、AES、Token、Sentry 上传凭据和签名材料保持 Git 忽略，不写入公开文档或构建日志。
- 从该品牌私密配置准备生产输入；AES 可以存在于被忽略的 flavor 配置中，不能沿用早期“生成文件恒为空、从开发 secrets 文档补 key”的说法。
- 生产包使用该品牌原签名。缺少签名材料时停止生产打包，不以 debug 签名替代，也不生成新的 keystore 冒充原签名。
- 构建前核对 SDK path、lockfile、子模块和生成代码顺序；准备工具成功不等于 APK 已生成或业务已入包。

品牌准备工具可按目标使用，例如：

```bash
dart run tool/prepare_flavor.dart --flavor brand_a --target prod --android-signing
```

这一步只生成配置与签名输入。完整 release 使用上表入口，并按当前 DEVELOPMENT / skill 固定版本、ABI、dart-define 和本地构建参数。`scripts/build_local.sh` 已是标准 Android 协调器的薄包装；它完成构建、核验和符号上传，下载站发布按任务范围另行执行。

## Release 构建与核验

1. 保存源码、SDK commit、lockfile、品牌、版本、构建号、buildTag、ABI 和签名证书等批次输入；保留需要回退的旧 APK 与报告。
2. 执行该修改对应的静态检查、测试和守卫。当前未关闭事项及设备验收边界以 STATUS 为准，隔离测试通过不等于整套客户端已验收。
3. 本机 Dart 业务改动的发布执行项目 `flutter clean`，然后严格使用当前 lockfile 重新解析依赖并完整编译。项目 clean 与全局 SDK / Gradle / Pub / Go 缓存清理是不同动作。
4. 使用 aapt 检查包名、名称、原生版本、min/target SDK、debuggable 和 ABI；使用 apksigner 验签并比较原品牌证书，使用 zipalign 检查 APK 对齐。
5. 核对必需原生库、品牌 fallback，以及未将 flavor、keystore 或生成的敏感输入作为独立文件误打入 APK。
6. 比较最终 APK 内 `libapp.so` 的 AOT `.text` 和 `.rodata` 与本轮 Flutter 输出，使用 [check_apk_aot.py](https://github.com/wvjh3z/proxy-suite-docs/blob/upgrade/flclash-v0.9.2/skills/xflclash-android-release/scripts/check_apk_aot.py)。签名成功、versionCode 增加或 APK hash 变化均不能替代业务代码入包核验。
7. 核验后才复制到 dist、写校验和与报告、更新计数；下载安装后的实际品牌、账号、订阅、节点和 VPN 行为按任务范围另行验收。

完整 clean 是本机曾出现 Gradle 合并旧 Dart 库后的规避措施。AOT 代码段比较证明当轮代码入包；签名、APK 对齐和组件测试各证明自己的边界，不能因此宣称所有设备或 ELF 页大小均已验证。

## Debug、下载站与正式发布

Debug 用于开发输入、日志与界面验证；生产 release 使用生产品牌配置和原签名。不同构建的 applicationId、后缀和签名以实际工程与产物为准，不沿用早期文档写死的通用包名。覆盖安装必须满足同一 applicationId、签名兼容及系统版本规则。

本机原型与安卓下载站的配置和发布流程见 [NGINX 维护](https://github.com/wvjh3z/proxy-suite-docs/blob/upgrade/flclash-v0.9.2/DEVELOPMENT.md#nginx-原型与安卓下载服务)。现有策略为同名覆盖 APK，构建号与大小在下载页及 manifest 中记录，不增加 build-N 下载目录。只有任务授权包含下载站发布时才执行部署，并核对页面、完整下载、Range、校验和及原型服务状态。

上传源码、测试下载站更新和 AppVersion 自更新清单发布是不同动作。正式发布要维护 [CHANGELOG_XBOARD](../CHANGELOG_XBOARD.md)，按 [更新契约](https://github.com/wvjh3z/proxy-suite-docs/blob/upgrade/flclash-v0.9.2/CONTRACTS.md#免登录自更新) 核对每包 hash、镜像、版本与 ABI；更新插件生产配置、创建 release/tag 或推送安装包都按具体任务授权执行。

早期构建说明曾包含旧 `.kiro` 路径、开发 key 补写、debug 签名回退及旧下载目录；这些步骤已经由当前 Docs 承接，不作为现行生产流程。

## 构建失败经验（客户端内维护）

任何构建、打包或必要验收失败，先查[统一经验入口](../docs/build-failures/README.md)，按底座版本定位历史事件。修复必须同步记录根因、代码/测试变更、正负控和正式入口验收，未复验不能标记关闭。v0.8.93、v0.9.1与当前v0.9.2经验均在该目录，随客户端提交；外部Docs仅保留导航。
