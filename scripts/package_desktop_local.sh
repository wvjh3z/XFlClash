#!/usr/bin/env bash
# 本地「桌面正式安装包」打包脚本（形态 A，多品牌）—— 与 CI `.github/workflows/release-package.yml`
# 同款产物（deb/AppImage/rpm/exe/zip/dmg），复刻其打包链路 + 固化跨平台构建经验，便于在
# 任意桌面机器（Linux/macOS/Windows-gitbash）本地复现 CI，无需上 GitHub 验证。
#
# ⚠️ 桌面包必须在「目标 OS 上」构建（无法交叉编译）：
#   - Linux 主机  → deb / AppImage（+ rpm，仅当 rpm < 4.20，见下）
#   - macOS 主机  → dmg（arm64 或 amd64，按主机架构）
#   - Windows 主机（Git-Bash/MSYS）→ exe / zip
#   本机若与 target OS 不符，脚本直接报错退出（不会产出错误产物）。
#
# 用法:
#   bash scripts/package_desktop_local.sh [flavor] [target] [选项]
#     flavor  : brand_a（默认）| brand_b
#     target  : auto（默认，按主机 OS+架构推断）| linux-amd64 | linux-arm64
#               | windows-amd64 | macos-amd64 | macos-arm64
#   选项:
#     --install-deps : 先装本平台打包依赖（Linux apt / macOS brew+npm；需要 sudo/brew）
#     --no-sentry    : 跳过 Sentry 符号上传（默认：有 flavors/sentry-cli.token + sentry-cli 才传）
#   例：
#     bash scripts/package_desktop_local.sh brand_a auto
#     bash scripts/package_desktop_local.sh brand_b linux-amd64 --install-deps
#
# 产物（统一收口为 AppVersion 插件/CI 同款命名，供 v0.3 自更新拼下载 URL）：
#   dist/{updatePackageName}-{产品版本}-{平台}-{arch}{后缀}
#   例：omo-0.0.1-linux-amd64.deb / ds-0.0.1-macos-arm64.dmg / omo-0.0.1-windows-amd64-setup.exe
#
# ───────── 固化的跨平台构建经验（来自 CI 实跑，见 .kiro/PATCHES.md「多平台打包 CI 跨平台经验」）─────────
#   #2 Linux 打包依赖：webkit2gtk-4.1/libsoup-3.0（desktop_webview_window）+ libcurl（sentry-native）
#      + libsecret-1/jsoncpp（flutter_secure_storage）+ ninja/gtk/appindicator/keybinder + patchelf/fuse
#      + appimagetool（按 arch）。本机缺则 --install-deps 装，或脚本检查后给提示。
#   #3 可移植 shell：一律 ${VAR} 花括号（macOS bash 3.2 多字节吞字节）；base64 用 `tr 去空白 | base64 -d`
#      （BSD 无 -i）；正则用 POSIX [[:space:]]（非 GNU \s）；sed 就地改用临时文件（BSD sed -i 需参数）。
#   #4 flutter_distributor 不靠 PATH → `dart pub global run flutter_distributor:main`。
#   #6 rpm 仅在 rpm < 4.20 主机打（rpm 4.20+ 改了 %install 工作目录 → vendored maker 失败）。自动判定跳过。
#   #8 rpm 的 Name:/二进制名/路径标识 %{name} 取 distribute_options app_name，必须 ASCII 无空格 →
#      中文 appName（如「袋鼠加速」）净化为空时回退 updatePackageName（omo/ds）。可见品牌名走 make_config
#      的 display_name（inject_desktop_brand 注入中文），不受影响。
#
# 版本号（与 build_local.sh / CI 一致）:
#   产品版本 XB_PRODUCT_VERSION ← flavor.yaml versionName（关于页显示，自有）
#   底座 build-name            ← pubspec.yaml version（FlClash，喂 packageInfo）
#   versionCode build-number   ← scripts/build_number.txt
set -euo pipefail

# ───────── 参数解析 ─────────
FLAVOR="brand_a"
TARGET="auto"
INSTALL_DEPS=0
NO_SENTRY=0
for arg in "$@"; do
  case "${arg}" in
    brand_a|brand_b)                         FLAVOR="${arg}" ;;
    auto|linux-amd64|linux-arm64|windows-amd64|macos-amd64|macos-arm64) TARGET="${arg}" ;;
    --install-deps)                          INSTALL_DEPS=1 ;;
    --no-sentry)                             NO_SENTRY=1 ;;
    *) echo "✗ 未知参数：${arg}"; exit 2 ;;
  esac
done

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "${REPO_DIR}"

FLAVOR_YAML="flavors/${FLAVOR}/flavor.yaml"
[ -f "${FLAVOR_YAML}" ] || { echo "✗ 找不到 flavor 配置：${FLAVOR_YAML}"; exit 1; }

# ───────── 主机 OS / 架构探测 + target 推断 + 交叉编译守卫 ─────────
case "$(uname -s)" in
  Linux)  HOST_OS="linux" ;;
  Darwin) HOST_OS="macos" ;;
  MINGW*|MSYS*|CYGWIN*) HOST_OS="windows" ;;
  *) echo "✗ 不支持的主机 OS：$(uname -s)"; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64|amd64)  HOST_ARCH="amd64" ;;
  aarch64|arm64) HOST_ARCH="arm64" ;;
  *) echo "✗ 不支持的主机架构：$(uname -m)"; exit 1 ;;
esac

if [ "${TARGET}" = "auto" ]; then
  TARGET="${HOST_OS}-${HOST_ARCH}"
  echo "ℹ target=auto → 按主机推断为 ${TARGET}"
fi
PLATFORM="${TARGET%-*}"   # linux / macos / windows
ARCH="${TARGET##*-}"      # amd64 / arm64

if [ "${PLATFORM}" != "${HOST_OS}" ]; then
  echo "✗ 桌面包不能交叉编译：target=${TARGET} 但当前主机是 ${HOST_OS}/${HOST_ARCH}。"
  echo "  请在对应 OS 的机器上构建（或用 CI release-package.yml 跑全平台）。"
  exit 1
fi
if [ "${PLATFORM}" = "macos" ] && [ "${ARCH}" != "${HOST_ARCH}" ]; then
  echo "✗ macOS 按主机架构出包：主机是 ${HOST_ARCH}，无法在此机出 macos-${ARCH}。"
  exit 1
fi

# ───────── 必备工具检查（硬失败，给安装提示）─────────
need() { command -v "${1}" >/dev/null 2>&1 || { echo "✗ 缺少工具：${1}（${2}）"; MISSING=1; }; }
MISSING=0
need flutter "安装 Flutter SDK"
need dart    "随 Flutter 附带"
need git     "版本控制"
need jq      "合成 env.json（Linux: apt install jq / macOS: brew install jq / Win: choco install jq）"
[ "${MISSING}" = "1" ] && { echo "→ 补齐上述工具后重试"; exit 1; }

# ───────── 打包依赖（可选 --install-deps；否则仅检查 + 提示）─────────
install_linux_deps() {
  echo "=== 安装 Linux 打包依赖（sudo apt）==="
  sudo apt-get update -y
  sudo apt-get install -y ninja-build libgtk-3-dev libayatana-appindicator3-dev libkeybinder-3.0-dev \
    libwebkit2gtk-4.1-dev libsoup-3.0-dev libcurl4-openssl-dev libsecret-1-dev libjsoncpp-dev patchelf
  sudo apt-get install -y libfuse2 || sudo apt-get install -y libfuse2t64 || true
  if [ "${ARCH}" = "amd64" ]; then AIT_ARCH="x86_64"; else AIT_ARCH="aarch64"; fi
  if ! command -v appimagetool >/dev/null 2>&1; then
    sudo wget -O /usr/local/bin/appimagetool \
      "https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-${AIT_ARCH}.AppImage"
    sudo chmod +x /usr/local/bin/appimagetool
  fi
}
install_macos_deps() {
  echo "=== 安装 macOS 打包依赖（npm appdmg）==="
  command -v appdmg >/dev/null 2>&1 || npm install -g appdmg
}

if [ "${INSTALL_DEPS}" = "1" ]; then
  case "${PLATFORM}" in
    linux)   install_linux_deps ;;
    macos)   install_macos_deps ;;
    windows) echo "ℹ Windows 无需额外打包依赖（Inno Setup 由 flutter_distributor 自带处理）" ;;
  esac
fi

# 软检查（不阻断，缺啥给提示，让 flutter_distributor 在缺依赖时报错更易懂）。
if [ "${PLATFORM}" = "linux" ]; then
  command -v appimagetool >/dev/null 2>&1 || echo "⚠ 缺 appimagetool（AppImage 会失败）；可加 --install-deps"
  pkg-config --exists webkit2gtk-4.1 2>/dev/null || echo "⚠ 缺 libwebkit2gtk-4.1-dev（桌面 WebView 构建会失败）；可加 --install-deps"
fi
[ "${PLATFORM}" = "macos" ] && { command -v appdmg >/dev/null 2>&1 || echo "⚠ 缺 appdmg（dmg 会失败）；可加 --install-deps"; }

# ───────── rpm 目标判定（经验 #6：rpm 4.20+ 与 vendored maker 不兼容）─────────
WANT_RPM=0
if [ "${PLATFORM}" = "linux" ] && [ "${ARCH}" = "amd64" ]; then
  if command -v rpmbuild >/dev/null 2>&1 && command -v rpm >/dev/null 2>&1; then
    RPM_VER="$(rpm --version 2>/dev/null | awk '{print $3}')"
    RPM_MAJOR="${RPM_VER%%.*}"; RPM_REST="${RPM_VER#*.}"; RPM_MINOR="${RPM_REST%%.*}"
    if [ "${RPM_MAJOR:-0}" -gt 4 ] 2>/dev/null || { [ "${RPM_MAJOR:-0}" -eq 4 ] && [ "${RPM_MINOR:-0}" -ge 20 ]; } 2>/dev/null; then
      echo "⚠ 本机 rpm ${RPM_VER} ≥ 4.20 → 跳过 rpm（与 vendored flutter_distributor maker 不兼容；rpm 请用 CI/ubuntu-22.04）"
    else
      WANT_RPM=1
    fi
  else
    echo "ℹ 未装 rpmbuild → 跳过 rpm（如需本地 rpm，须 rpm < 4.20 的发行版）"
  fi
fi

# ───────── 版本号 ─────────
VERSION_NAME="$(grep -m1 -E '^[[:space:]]*versionName:' "${FLAVOR_YAML}" | sed -E 's/.*versionName:[[:space:]]*"?([^"#]+)"?.*/\1/' | xargs)"
[ -n "${VERSION_NAME}" ] || { echo "✗ 未能从 ${FLAVOR_YAML} 读到 versionName"; exit 1; }
BASE_VERSION="$(grep -m1 -E '^version:' pubspec.yaml | sed -E 's/^version:[[:space:]]*([0-9.]+).*/\1/' | xargs)"
[ -n "${BASE_VERSION}" ] || BASE_VERSION="0.8.93"
BUILD_NUMBER="$(cat scripts/build_number.txt 2>/dev/null || echo 1)"
TAG="$(date +%Y%m%d%H%M)"

echo "=== package: flavor=${FLAVOR} target=${TARGET} ==="
echo "    产品版本=${VERSION_NAME}  底座(build-name)=${BASE_VERSION}  versionCode=${BUILD_NUMBER}  tag=${TAG}  rpm=${WANT_RPM}"

# ───────── 依赖 + codegen（与 CI 同序：SDK build_runner → client codegen）─────────
echo "=== flutter pub get ==="
flutter pub get

if [ -d "../Xboard_sdk" ]; then
  echo "=== SDK build_runner（../Xboard_sdk）==="
  ( cd ../Xboard_sdk && dart pub get && dart run build_runner build --delete-conflicting-outputs )
else
  echo "⚠ 未找到 sibling ../Xboard_sdk（应与 XFlClash 平级）；若 pub get 已解析到它则忽略，否则会编译失败"
fi

echo "=== client codegen ==="
dart run build_runner build --delete-conflicting-outputs

# ───────── flavor 注入（桌面：不带 --android-signing）+ 品牌注入 + 图标 ─────────
echo "=== prepare_flavor（生成 flavor_defines.json，含 aesKey）==="
dart run tool/prepare_flavor.dart --flavor "${FLAVOR}" --target prod

echo "=== inject_desktop_brand（窗口标题 / 打包 display_name / 图标）==="
dart run tool/inject_desktop_brand.dart --flavor "${FLAVOR}"

echo "=== generate desktop icons ==="
dart run flutter_launcher_icons -f flutter_launcher_icons.yaml

# ───────── Align package app_name → ASCII（经验 #8：rpm Name 必须 ASCII 无空格）─────────
APP_NAME="$(grep -m1 -E '^[[:space:]]*appName:' "${FLAVOR_YAML}" | sed -E 's/.*appName:[[:space:]]*"?([^"#]+)"?.*/\1/' | xargs)"
ASCII_NAME="$(printf '%s' "${APP_NAME}" | LC_ALL=C tr -cd 'A-Za-z0-9_.-')"
if [ -z "${ASCII_NAME}" ]; then
  ASCII_NAME="$(grep -m1 -E '^[[:space:]]*updatePackageName:' "${FLAVOR_YAML}" | sed -E 's/.*updatePackageName:[[:space:]]*"?([^"#]+)"?.*/\1/' | xargs)"
  echo "ℹ appName「${APP_NAME}」非 ASCII → app_name 回退到 updatePackageName「${ASCII_NAME}」"
fi
if [ -n "${ASCII_NAME}" ]; then
  # 可移植就地编辑（BSD sed -i 需参数 → 临时文件）。
  sed -E "s/^app_name:.*/app_name: '${ASCII_NAME}'/" distribute_options.yaml > distribute_options.yaml.tmp \
    && mv distribute_options.yaml.tmp distribute_options.yaml
fi

# ───────── Windows：先编 Go 核心取 CORE_SHA256（运行时核心完整性校验）─────────
SHA=""
if [ "${PLATFORM}" = "windows" ]; then
  echo "=== build Go core + CORE_SHA256（Windows）==="
  ( cd plugins/setup/buildkit/build_tool && dart pub get && dart run build_tool windows --root-dir "${REPO_DIR}" )
  [ -f core_sha256.json ] && SHA="$(jq -r '.CORE_SHA256 // ""' core_sha256.json)"
fi

# ───────── 合成 env.json（保住全部 XB_* defines；不走 setup.dart）─────────
echo "=== compose env.json ==="
jq -n \
  --argjson flavor "$(cat flavor_defines.json)" \
  --arg env "stable" --arg sha "${SHA}" --arg tag "${TAG}" --arg pv "${VERSION_NAME}" --arg bn "${BUILD_NUMBER}" \
  '$flavor + {APP_ENV:$env, CORE_SHA256:$sha, XB_FORM_A:"true", XB_BUILD_TAG:$tag, XB_PRODUCT_VERSION:$pv, XB_BUILD_NUMBER:$bn}' \
  > env.json
echo "  env.json（脱敏 XB_AES_KEY_B64）："; jq 'del(.XB_AES_KEY_B64)' env.json

# ───────── 激活 vendored flutter_distributor（经验 #4：不靠 PATH）─────────
echo "=== activate flutter_distributor ==="
dart pub global activate -s path plugins/flutter_distributor/packages/flutter_distributor >/dev/null

# ───────── 打包 ─────────
COMMON="dart-define-from-file=env.json,build-name=${BASE_VERSION},build-number=${BUILD_NUMBER}"
case "${PLATFORM}" in
  windows) TARGETS="exe,zip"; BUILD_ARGS="${COMMON},split-debug-info=build/debug-info" ;;
  macos)   TARGETS="dmg";     BUILD_ARGS="${COMMON}" ;;  # macOS 不支持 split-debug-info（用 sentry-cocoa + dSYM）
  linux)
    if [ "${WANT_RPM}" = "1" ]; then TARGETS="deb,appimage,rpm"; else TARGETS="deb,appimage"; fi
    BUILD_ARGS="${COMMON},split-debug-info=build/debug-info" ;;
esac

echo "=== flutter_distributor package（platform=${PLATFORM} targets=${TARGETS}）==="
dart pub global run flutter_distributor:main package \
  --skip-clean \
  --platform "${PLATFORM}" \
  --targets "${TARGETS}" \
  --flutter-build-args="${BUILD_ARGS}" \
  --description "${ARCH}"

# ───────── 统一产物命名（AppVersion 插件/CI 同款；v0.3 自更新按此拼下载 URL）─────────
PKG="$(grep -m1 -E '^[[:space:]]*updatePackageName:' "${FLAVOR_YAML}" | sed -E 's/.*updatePackageName:[[:space:]]*"?([^"#]+)"?.*/\1/' | xargs)"
[ -n "${PKG}" ] || { echo "✗ flavor.yaml 缺 updatePackageName"; exit 1; }
echo "=== normalize dist 命名 → ${PKG}-${VERSION_NAME}-${PLATFORM}-${ARCH}* ==="
( cd dist
  shopt -s nullglob
  case "${PLATFORM}" in
    windows)
      for f in *setup.exe; do mv -f "${f}" "${PKG}-${VERSION_NAME}-windows-${ARCH}-setup.exe"; done
      for f in *.zip;       do mv -f "${f}" "${PKG}-${VERSION_NAME}-windows-${ARCH}.zip"; done ;;
    macos)
      for f in *.dmg; do mv -f "${f}" "${PKG}-${VERSION_NAME}-macos-${ARCH}.dmg"; done ;;
    linux)
      for f in *.AppImage; do mv -f "${f}" "${PKG}-${VERSION_NAME}-linux-${ARCH}.AppImage"; done
      for f in *.deb;      do mv -f "${f}" "${PKG}-${VERSION_NAME}-linux-${ARCH}.deb"; done
      for f in *.rpm;      do mv -f "${f}" "${PKG}-${VERSION_NAME}-linux-${ARCH}.rpm"; done ;;
  esac )

# ───────── Sentry 符号上传（与 build_local.sh 同源：flavors/sentry-cli.token；缺则跳过）─────────
if [ "${NO_SENTRY}" = "0" ]; then
  TOKEN_FILE="flavors/sentry-cli.token"
  if [ -f "${TOKEN_FILE}" ] && command -v sentry-cli >/dev/null 2>&1; then
    case "${FLAVOR}" in brand_b) SENTRY_PROJECT="daishu" ;; *) SENTRY_PROJECT="omofly" ;; esac
    export SENTRY_AUTH_TOKEN="$(tr -d '[:space:]' < "${TOKEN_FILE}")"
    export SENTRY_ORG="ka-chiu-lee"
    echo "=== Sentry 符号上传（project=${SENTRY_PROJECT}）==="
    if [ "${PLATFORM}" != "macos" ]; then
      sentry-cli debug-files upload --include-sources --project "${SENTRY_PROJECT}" build/debug-info \
        || echo "⚠ Dart 符号上传失败（非阻断）"
    fi
    case "${PLATFORM}" in
      linux)   sentry-cli debug-files upload --project "${SENTRY_PROJECT}" build/linux 2>/dev/null || true ;;
      windows) sentry-cli debug-files upload --project "${SENTRY_PROJECT}" build/windows 2>/dev/null || true ;;
      macos)   sentry-cli debug-files upload --project "${SENTRY_PROJECT}" build/macos/Build/Products/Release 2>/dev/null || true ;;
    esac
  else
    echo "ℹ 跳过 Sentry 符号上传（无 ${TOKEN_FILE} 或本机未装 sentry-cli）"
  fi
fi

# ───────── 完成 ─────────
echo "=== done ==="
echo "  ${FLAVOR} 产品版本 v${VERSION_NAME} (build ${BUILD_NUMBER}) · 底座 ${BASE_VERSION} · ${PLATFORM}-${ARCH}"
echo "=== dist 产物 ==="
ls -la dist/ 2>/dev/null || echo "  (无 dist —— 检查上面打包日志)"
