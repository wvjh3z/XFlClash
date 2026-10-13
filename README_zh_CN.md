<div>

[**English**](README.md)

</div>

## XFlclash

XFlclash 是 [FlClash](https://github.com/chen08209/FlClash) 的二次开发，品牌 Xboard 客户端业务在 `lib/xboard/` 中维护。当前产品采用形态 A「首页 / 节点 / 我的」界面，FlClash 底座继续负责内核、VPN、代理、Profile 和平台集成。当前底座为 **FlClash v0.8.93**。

### 项目文档与开发入口

- [产品变更记录](CHANGELOG_XBOARD.md)、[客户端协作说明](AGENTS.md)、[安全决策](SECURITY.md)。
- [当前项目文档](https://github.com/wvjh3z/proxy-suite-docs/blob/main/README.md)：架构、契约、开发环境、缺陷及实际验证记录。
- [Xboard SDK fork](https://github.com/wvjh3z/Xboard_sdk)：Xboard 与客户端之间的协议适配层。
- [UI 框架](.github/UI_FRAMEWORK.md)、[golden 环境](test/xboard/golden/README.md)、[构建入口](.github/BUILD_AND_RELEASE.md)、[更新机制](.github/UPDATE_MECHANISM.md)。

**SDK 与当前 Docs 为私有仓库，需要维护者授予 GitHub 访问权限；未授权时链接可能显示 404。** 本地工具中的跨仓相对路径指平级 checkout，不是客户端仓库内目录。工作区保持以下布局：

```text
workspace/
├── XFlclash/       当前客户端仓库
├── Xboard_sdk/     私有 SDK；pubspec.yaml 的 path 依赖
└── Docs/           私有 proxy-suite-docs 仓库
```

二开构建与验证遵循 [DEVELOPMENT](https://github.com/wvjh3z/proxy-suite-docs/blob/main/DEVELOPMENT.md)：复用已跟踪的 lockfile，准备品牌私密输入及原签名，先生成 SDK 代码再生成客户端。真实 flavor、AES、Token、签名和生成的敏感配置不提交 Git。Xboard 主程序由外部维护者持续更新、保持只读；客户端、SDK 与插件在各自范围内维护。

产品变化单独记录，不改写上游 CHANGELOG。源码推送、隔离测试通过不等于正式发布或整套设备验收；当前实现、暂缓问题和验证边界见 [STATUS](https://github.com/wvjh3z/proxy-suite-docs/blob/main/STATUS.md)。本 fork 的发行资产入口为 [XFlClash releases](https://github.com/wvjh3z/XFlClash/releases)。

## FlClash 上游参考

下方保留上游介绍、截图、下载和构建资料，适用对象为 FlClash。上游下载链接安装 FlClash，品牌 XFlclash 应按上面的 fork 流程构建。保留 FlClash 原作者归属及 [GPL-3.0 许可证](LICENSE)。

[![Downloads](https://img.shields.io/github/downloads/chen08209/FlClash/total?style=flat-square&logo=github)](https://github.com/chen08209/FlClash/releases/)[![Last Version](https://img.shields.io/github/release/chen08209/FlClash/all.svg?style=flat-square)](https://github.com/chen08209/FlClash/releases/)[![License](https://img.shields.io/github/license/chen08209/FlClash?style=flat-square)](LICENSE)

[![Channel](https://img.shields.io/badge/Telegram-Channel-blue?style=flat-square&logo=telegram)](https://t.me/FlClash)

基于ClashMeta的多平台代理客户端，简单易用，开源无广告。

on Desktop:
<p style="text-align: center;">
    <img alt="desktop" src="snapshots/desktop.gif">
</p>

on Mobile:
<p style="text-align: center;">
    <img alt="mobile" src="snapshots/mobile.gif">
</p>

## Features

✈️ 多平台: Android, Windows, macOS and Linux

💻 自适应多个屏幕尺寸,多种颜色主题可供选择

💡 基本 Material You 设计, 类[Surfboard](https://github.com/getsurfboard/surfboard)用户界面

☁️ 支持通过WebDAV同步数据

✨ 支持一键导入订阅, 深色模式

## Use

### Linux

⚠️ 使用前请确保安装以下依赖

   ```bash
    sudo apt-get install libayatana-appindicator3-dev
    sudo apt-get install libkeybinder-3.0-dev
   ```

### Android

支持下列操作

   ```bash
    com.follow.clash.action.START
    
    com.follow.clash.action.STOP
    
    com.follow.clash.action.TOGGLE
   ```

## Download

<a href="https://chen08209.github.io/FlClash-fdroid-repo/repo?fingerprint=789D6D32668712EF7672F9E58DEEB15FBD6DCEEC5AE7A4371EA72F2AAE8A12FD"><img alt="Get it on F-Droid" src="snapshots/get-it-on-fdroid.svg" width="200px"/></a> <a href="https://github.com/chen08209/FlClash/releases"><img alt="Get it on GitHub" src="snapshots/get-it-on-github.svg" width="200px"/></a>

## Build

1. 更新 submodules
   ```bash
   git submodule update --init --recursive
   ```

2. 安装 `Flutter` 以及 `Golang` 环境

3. 构建应用

    - android

        1. 安装  `Android SDK` ,  `Android NDK`

        2. 设置 `ANDROID_NDK` 环境变量

        3. 运行构建脚本

           ```bash
           dart setup.dart android
           ```

    - windows

        1. 你需要一个windows客户端

        2. 安装 `GCC`，`Inno Setup`

        3. 运行构建脚本

           ```bash
           dart setup.dart windows
           ```

    - linux

        1. 你需要一个linux客户端

        2. 依赖会由 setup 脚本自动安装，也可以手动安装：
           ```bash
           sudo apt-get install -y libayatana-appindicator3-dev libkeybinder-3.0-dev
           ```

        3. 运行构建脚本

           ```bash
           dart setup.dart linux
           ```

    - macOS

        1. 你需要一个macOS客户端

        2. 运行构建脚本

           ```bash
           dart setup.dart macos
           ```

## Star

支持开发者的最简单方式是点击页面顶部的星标（⭐）。

<p style="text-align: center;">
    <a href="https://api.star-history.com/svg?repos=chen08209/FlClash&Date">
        <img alt="start" width=50% src="https://api.star-history.com/svg?repos=chen08209/FlClash&Date"/>
    </a>
</p>
