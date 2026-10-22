<div>

[**简体中文**](README_zh_CN.md)

</div>

## XFlclash

XFlclash is a fork of [FlClash](https://github.com/chen08209/FlClash), with a branded Xboard client in `lib/xboard/`. The current product uses the Form A Home / Nodes / Mine interface; FlClash continues to provide the core, VPN, proxy, Profile and platform integration. This independent branch targets **FlClash v0.9.1**; native release/device validation is tracked in Docs/STATUS.

### Project documentation

- [Product changelog](CHANGELOG_XBOARD.md), [contributor instructions](AGENTS.md) and [security decisions](SECURITY.md).
- [Current documentation](https://github.com/wvjh3z/proxy-suite-docs/blob/main/README.md): architecture, contracts, development, known issues and verification records.
- [Xboard SDK fork](https://github.com/wvjh3z/Xboard_sdk): protocol adaptation between the client and Xboard.
- [UI framework](.github/UI_FRAMEWORK.md), [golden tests](test/xboard/golden/README.md), [build guide](.github/BUILD_AND_RELEASE.md) and [update guide](.github/UPDATE_MECHANISM.md).

**The SDK and documentation repositories are private and require maintainer-granted GitHub access.** Their relative paths in local tools refer to sibling checkouts, not directories inside this client repository. Keep this layout:

```text
workspace/
├── XFlclash/       this client repository
├── Xboard_sdk/     private SDK; required by pubspec.yaml
└── Docs/           private proxy-suite-docs repository
```

For fork development, follow [DEVELOPMENT](https://github.com/wvjh3z/proxy-suite-docs/blob/main/DEVELOPMENT.md). Use the checked-in lockfiles, prepare the private brand inputs and original signing material, and generate SDK code before client code. Real flavor configuration, AES keys, Tokens, signing files and generated sensitive inputs must stay out of Git. The Xboard main program is maintained externally and remains read-only; client, SDK and plugin changes are maintained within their respective boundaries.

Product changes are recorded separately from the upstream changelog. A source push or a successful isolated test is not a formal release or device acceptance; the current status and deferred issues are maintained in [STATUS](https://github.com/wvjh3z/proxy-suite-docs/blob/main/STATUS.md). For fork release assets, see [XFlClash releases](https://github.com/wvjh3z/XFlClash/releases).

## Upstream FlClash reference

The original introduction, screenshots, download links and build instructions below describe upstream FlClash. Upstream download links install FlClash; branded XFlclash builds use the fork workflow above. FlClash's original authorship and [GPL-3.0 license](LICENSE) are retained.

[![Downloads](https://img.shields.io/github/downloads/chen08209/FlClash/total?style=flat-square&logo=github)](https://github.com/chen08209/FlClash/releases/)[![Last Version](https://img.shields.io/github/release/chen08209/FlClash/all.svg?style=flat-square)](https://github.com/chen08209/FlClash/releases/)[![License](https://img.shields.io/github/license/chen08209/FlClash?style=flat-square)](LICENSE)

[![Channel](https://img.shields.io/badge/Telegram-Channel-blue?style=flat-square&logo=telegram)](https://t.me/FlClash)

A multi-platform proxy client based on ClashMeta, simple and easy to use, open-source and ad-free.

on Desktop:
<p style="text-align: center;">
    <img alt="desktop" src="snapshots/desktop.gif">
</p>

on Mobile:
<p style="text-align: center;">
    <img alt="mobile" src="snapshots/mobile.gif">
</p>

## Features

✈️ Multi-platform: Android, Windows, macOS and Linux

💻 Adaptive multiple screen sizes, Multiple color themes available

💡 Based on Material You Design, [Surfboard](https://github.com/getsurfboard/surfboard)-like UI

☁️ Supports data sync via WebDAV

✨ Support subscription link, Dark mode

## Use

### Linux

⚠️ Make sure to install the following dependencies before using them

   ```bash
    sudo apt-get install libayatana-appindicator3-dev
    sudo apt-get install libkeybinder-3.0-dev
   ```

### Android

Support the following actions

   ```bash
    com.follow.clash.action.START
    
    com.follow.clash.action.STOP
    
    com.follow.clash.action.TOGGLE
   ```

## Download

<a href="https://chen08209.github.io/FlClash-fdroid-repo/repo?fingerprint=789D6D32668712EF7672F9E58DEEB15FBD6DCEEC5AE7A4371EA72F2AAE8A12FD"><img alt="Get it on F-Droid" src="snapshots/get-it-on-fdroid.svg" width="200px"/></a> <a href="https://github.com/chen08209/FlClash/releases"><img alt="Get it on GitHub" src="snapshots/get-it-on-github.svg" width="200px"/></a>

## Build

1. Update submodules
   ```bash
   git submodule update --init --recursive
   ```

2. Install `Flutter` and `Golang` environment

3. Build Application

    - android

        1. Install `Android SDK`, `Android NDK`

        2. Set `ANDROID_NDK` environment variable

        3. Run build script

           ```bash
           dart setup.dart android
           ```

    - windows

        1. Requires a Windows client

        2. Install `GCC`, `Inno Setup`

        3. Run build script

           ```bash
           dart setup.dart windows
           ```

    - linux

        1. Requires a Linux client

        2. Dependencies are auto-installed by setup script, or manually:
           ```bash
           sudo apt-get install -y libayatana-appindicator3-dev libkeybinder-3.0-dev
           ```

        3. Run build script

           ```bash
           dart setup.dart linux
           ```

    - macOS

        1. Requires a macOS client

        2. Run build script

           ```bash
           dart setup.dart macos
           ```

## Star

The easiest way to support developers is to click on the star (⭐) at the top of the page.

<p style="text-align: center;">
    <a href="https://api.star-history.com/svg?repos=chen08209/FlClash&Date">
        <img alt="start" width=50% src="https://api.star-history.com/svg?repos=chen08209/FlClash&Date"/>
    </a>
</p>
