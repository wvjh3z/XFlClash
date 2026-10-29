<!-- docs-migration:start -->
> **当前更新导航与上游参考。** 完整接口与失败语义见 [CONTRACTS](https://github.com/wvjh3z/proxy-suite-docs/blob/main/CONTRACTS.md#免登录自更新)，运行链见 [ARCHITECTURE](https://github.com/wvjh3z/proxy-suite-docs/blob/main/ARCHITECTURE.md#更新检查提示与安装的运行链)，发布及平台验收见 [DEVELOPMENT](https://github.com/wvjh3z/proxy-suite-docs/blob/main/runbooks/PLATFORM_REGRESSION.md#自更新排障与平台验收)。Docs 为私有仓库，需要 GitHub 授权；本地 checkout 为客户端平级的 `Docs/`。
<!-- docs-migration:end -->

# XFlclash 更新机制

XFlclash 当前使用形态 A 商业 UI，FlClash 底座仍为 **v0.8.93**。形态 A 屏蔽 FlClash 自带的上游自动更新检查，产品更新另走 Xboard AppVersion 插件与私有 SDK。不能把 FlClash 的 release 当成本品牌产品的更新源。

## 1. 当前产品更新链

1. SDK 调用免登录接口 `GET /api/v1/guest/app/version`，携带 platform、ABI 和当前构建号。插件返回版本、下载镜像、SHA-256、changelog 与 force；清单未配置等场景可返回空数据。
2. [XbUpdateService](../lib/xboard/services/xb_update_service.dart) 比较服务端 versionCode 与编译期 `XB_BUILD_NUMBER`，自动结果写入更新 provider；产品关于页也提供手动检查。
3. [更新弹窗](../lib/xboard/widgets/xb_update_dialog.dart) 展示清单与下载操作。正常非空 hash 的应用内下载交给 [XbApkDownloader](../lib/xboard/services/xb_apk_downloader.dart)，核对文件 SHA-256 后才调用平台安装入口；浏览器下载没有经过此应用内校验器。
4. Android 交给系统安装器，Windows 启动安装程序，Linux AppImage 尝试同目录替换并启动，macOS 走浏览器下载 DMG。安装动作已启动与目标版本已成功运行分别验收。

冷启动、手动检查、resume/VPN 自动检查有各自触发和节流规则，详见当前 ARCHITECTURE；不能沿用早期“统一 30 分钟”或“所有触发均 24 小时”的说法。Android 更新 ABI 读取 `XB_ANDROID_ABI`，Gradle 的 `XB_TARGET_ABI` 是另一输入。每个发布批次都核对实际 APK 与 Dart 配置，不能只凭文件名或默认值判断。

Xboard业务的SDK API、Bootstrap、加密订阅、端点探测与安装包下载继承宿主既有HttpOverrides，不改原FlClash全局HTTP或通用请求规则，不额外添加直连回退。业务Dart通道关闭持久连接，避免后续HTTPS复用旧代理隧道。应用内与浏览器共用合法URL的稳定地区排序，浏览器打开失败换源、成功才关窗；其实际网络出口仍由浏览器与系统决定。调用与平台验收见[ARCHITECTURE](https://github.com/wvjh3z/proxy-suite-docs/blob/main/ARCHITECTURE.md#更新检查提示与安装的运行链)、[DEVELOPMENT](https://github.com/wvjh3z/proxy-suite-docs/blob/main/runbooks/PLATFORM_REGRESSION.md#自更新排障与平台验收)。

产品展示版本、底座原生版本与构建号分别维护，见 [构建入口](BUILD_AND_RELEASE.md)。AppVersion 的 version_code 应对应批次 `XB_BUILD_NUMBER`，Android 覆盖安装另检查真实 versionCode、包名和原签名。

## 2. 已知边界与验收

当前缺口统一在 [STATUS](https://github.com/wvjh3z/proxy-suite-docs/blob/main/STATUS.md) 维护，包括 arm32 的更新 ABI、强制更新门控、下载异常的状态释放与清单撤回后旧提示等。字段或平台入口存在，不等于对应场景已经修复或真机验收。

下载校验一致不替代品牌发行签名；弹窗或安装服务返回成功不保证安装完成。发布前后应记录清单版本、目标平台/ABI、每包 hash、下载文件 hash、原签名和重启后的实际版本。生产插件配置、清单发布、下载安装和源代码推送是不同动作，按具体任务授权执行。

Xboard 主程序由外部维护者更新、保持只读。接口兼容在 SDK 和客户端处理，AppVersion 能力及配置定义在插件范围内维护，不为产品自更新改写主程序。

## 3. FlClash 上游更新屏蔽

[lib/providers/action.dart](../lib/providers/action.dart) 的 `autoCheckUpdate()` 保留形态 A gate：

```dart
Future<void> autoCheckUpdate() async {
  if (XboardConfig.current.formA) return;
  // 随后的 FlClash 上游更新逻辑保持由底座维护。
}
```

形态 A 使用自己的产品更新链；底座其他入口按源码及接缝范围核对。接缝点 #10 当前登记在 [PATCHES](https://github.com/wvjh3z/proxy-suite-docs/blob/main/PATCHES.md)，稳定符号在 [FLCLASH_ANCHORS](https://github.com/wvjh3z/proxy-suite-docs/blob/main/FLCLASH_ANCHORS.md) 维护。旧 `.kiro/PATCHES.md` 只是历史来源，不再要求读取或双写。

上游机制保留为同步参考：

| 关注点 | 当前源码入口与行为 |
| --- | --- |
| 启动自动检查 | `lib/state.dart` 调用 commonActionProvider 的 autoCheckUpdate |
| 手动检查 | `lib/views/about.dart` 的 _checkUpdate，经 request.checkForUpdate 与 checkUpdateResultHandle |
| 设置开关 | appSettingProvider.autoCheckUpdate，设置 UI 位于 `lib/views/application_setting.dart` |
| 请求层 | `lib/common/request.dart` 的 checkForUpdate，读取上游 GitHub 最新 release |
| 上游仓库来源 | `lib/common/constant.dart` 的 repository 常量 |
| 提示与下载 | `lib/providers/action.dart` 的 checkUpdateResultHandle；展示上游版本并跳对应 release |

这些是 FlClash 的上游发布机制。产品与底座版本独立，形态 A 不应将自己的 0.0.x 产品展示版本与上游 0.8.x release 混用。定位以当前源码和 anchors 为准，不继续复制会漂移的旧行号。

## 4. 历史方案的承接

早期文档曾建议把更新信息加入 Bootstrap、另设计 `latest_build / min_supported_build`，或复用解密协议。当前已接入 AppVersion guest API、SDK AppUpdateModel、产品更新服务与平台安装入口，这些早期建议不再作为待实现方案。Bootstrap、更新清单和安装包各按当前契约核对，不能从旧规划推导为已接线或强制升级已完成。

组件、规则和完整验收只在各自负责的当前文档维护；产品发布变化写 [CHANGELOG_XBOARD](../CHANGELOG_XBOARD.md)，上游 CHANGELOG 保留 FlClash 的历史。
