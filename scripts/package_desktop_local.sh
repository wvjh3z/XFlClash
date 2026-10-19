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
#     --audit-only   : 显式离线诊断：准备和校验符号，不上传
#     --no-sentry    : 显式诊断：跳过 Sentry；默认各平台缺 token/CLI/符号都失败
#   例：
#     bash scripts/package_desktop_local.sh brand_a auto
#     bash scripts/package_desktop_local.sh brand_b linux-amd64 --install-deps
#
# 产物（统一收口为 AppVersion 插件/CI 同款命名，供 v0.3 自更新拼下载 URL）：
#   dist/{updatePackageName}-{产品版本}-{平台}-{arch}{后缀}
#   例：omo-0.0.1-linux-amd64.deb / ds-0.0.1-macos-arm64.dmg / omo-0.0.1-windows-amd64-setup.exe
#
# ───────── 固化的跨平台构建经验（来自 CI 实跑，见 Docs/PATCHES.md「多平台打包 CI 跨平台经验」）─────────
#   #2 Linux 打包依赖：webkit2gtk-4.1/libsoup-3.0（desktop_webview_window）+ libcurl（sentry-native）
#      + libsecret-1/jsoncpp（flutter_secure_storage）+ ninja/gtk/appindicator/keybinder + patchelf/fuse
#      + 固定版本 appimagetool（按 host/target 校验后下载到 .local-build，免 FUSE）。
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

# Sentry upload credential isolation: only the controlled postbuild inherits it.
XFL_LOCAL_SENTRY_UPLOAD_TOKEN="${SENTRY_AUTH_TOKEN:-}"
export -n XFL_LOCAL_SENTRY_UPLOAD_TOKEN
unset SENTRY_AUTH_TOKEN SENTRY_MAINTENANCE_TOKEN
run_sentry_postbuild() {
  if [ -n "${XFL_LOCAL_SENTRY_UPLOAD_TOKEN}" ]; then
    SENTRY_AUTH_TOKEN="${XFL_LOCAL_SENTRY_UPLOAD_TOKEN}" python3 tool/postbuild_sentry_symbols.py "$@"
  else
    python3 tool/postbuild_sentry_symbols.py "$@"
  fi
}

# ───────── 参数解析 ─────────
FLAVOR="brand_a"
TARGET="auto"
INSTALL_DEPS=0
NO_SENTRY=0
AUDIT_ONLY=0
for arg in "$@"; do
  case "${arg}" in
    brand_a|brand_b)                         FLAVOR="${arg}" ;;
    auto|linux-amd64|linux-arm64|windows-amd64|macos-amd64|macos-arm64) TARGET="${arg}" ;;
    --install-deps)                          INSTALL_DEPS=1 ;;
    --no-sentry)                             NO_SENTRY=1 ;;
    --audit-only)                            AUDIT_ONLY=1 ;;
    *) echo "✗ 未知参数：${arg}"; exit 2 ;;
  esac
done
[ "${NO_SENTRY}" = "0" ] || [ "${AUDIT_ONLY}" = "0" ] || { echo "✗ --no-sentry 与 --audit-only 不能同时使用"; exit 2; }

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
if { [ "${PLATFORM}" = "macos" ] || [ "${PLATFORM}" = "linux" ]; } && [ "${ARCH}" != "${HOST_ARCH}" ]; then
  echo "✗ ${PLATFORM} 按主机架构出包：主机是 ${HOST_ARCH}，无法在此机出 ${PLATFORM}-${ARCH}。"
  exit 1
fi

# ───────── 必备工具检查（硬失败，给安装提示）─────────
need() { command -v "${1}" >/dev/null 2>&1 || { echo "✗ 缺少工具：${1}（${2}）"; MISSING=1; }; }
MISSING=0
need flutter "安装 Flutter SDK"
need dart    "随 Flutter 附带"
need git     "版本控制"
need python3 "Sentry 符号准备、审计和上传（Python 3.10+）"
[ "${MISSING}" = "1" ] && { echo "→ 补齐上述工具后重试"; exit 1; }

# ───────── 打包依赖（可选 --install-deps；否则仅检查 + 提示）─────────
install_linux_deps() {
  echo "=== 安装 Linux 打包依赖（sudo apt）==="
  sudo apt-get update -y
  sudo apt-get install -y ninja-build libgtk-3-dev libayatana-appindicator3-dev libkeybinder-3.0-dev \
    libwebkit2gtk-4.1-dev libsoup-3.0-dev libcurl4-openssl-dev libsecret-1-dev libjsoncpp-dev patchelf file squashfs-tools
  sudo apt-get install -y libfuse2 || sudo apt-get install -y libfuse2t64 || true
}
install_macos_deps() {
  echo "=== 安装 macOS 打包依赖（npm appdmg）==="
  npm install -g "appdmg@$(python3 tool/record_build_environment.py --print-appdmg-pin)"
}

if [ "${INSTALL_DEPS}" = "1" ]; then
  case "${PLATFORM}" in
    linux)   install_linux_deps ;;
    macos)   install_macos_deps ;;
    windows) echo "ℹ Windows 无需额外打包依赖（Inno Setup 由 flutter_distributor 自带处理）" ;;
  esac
fi

# AppImage 工具与真实契约必须通过；其余开发库缺失时给安装提示。
if [ "${PLATFORM}" = "linux" ]; then
  need file "安装 file（或加 --install-deps）"
  need unsquashfs "安装 squashfs-tools（或加 --install-deps）"
  [ "${MISSING}" = "0" ] || exit 1
  APPIMAGETOOL_BIN="$(python3 tool/prepare_appimagetool.py --target-arch "${ARCH}" --print-bin-dir)"
  export PATH="${APPIMAGETOOL_BIN}:${PATH}"
  # The cache lives outside build/: flutter clean below must not remove this PATH.
  APPIMAGETOOL_REQUIRE_REAL=1 python3 -m unittest tool.test.appimagetool_contract_test
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
BUILD_NUMBER="$(cat scripts/build_number.txt 2>/dev/null || echo 1)"
echo "=== package: flavor=${FLAVOR} target=${TARGET} build=${BUILD_NUMBER} ==="

# ───────── 依赖 + codegen（与 CI 同序：SDK build_runner → client codegen）─────────
echo "=== flutter clean + strict pub get ==="
flutter clean
flutter pub get --enforce-lockfile

if [ -d "../Xboard_sdk" ]; then
  echo "=== SDK build_runner（../Xboard_sdk）==="
  ( cd ../Xboard_sdk && flutter pub get --enforce-lockfile && dart run build_runner build )
else
  echo "✗ 未找到 sibling ../Xboard_sdk；正式打包要求严格解析 SDK 锁文件"
  exit 1
fi

echo "=== client codegen ==="
dart run build_runner build

# ───────── flavor 注入（桌面：不带 --android-signing）+ 品牌注入 + 图标 ─────────
echo "=== prepare_flavor（生成 flavor_defines.json，含 aesKey）==="
dart run tool/prepare_flavor.dart --flavor "${FLAVOR}" --target prod

CONTEXT_ARGS=(--flavor "${FLAVOR}" --platform "${PLATFORM}" --arch "${ARCH}"
  --build-number "${BUILD_NUMBER}" --source-revision "$(git rev-parse HEAD)" --align-package-name)
[ "${PLATFORM}" != "windows" ] || CONTEXT_ARGS+=(--include-zip)
[ "${WANT_RPM}" = "1" ] || CONTEXT_ARGS+=(--no-include-rpm)
dart run tool/prepare_release_context.dart "${CONTEXT_ARGS[@]}"
VERSION_NAME="$(python3 tool/release_pipeline.py value --key product_version)"
BASE_VERSION="$(python3 tool/release_pipeline.py value --key base_version)"

# 和CI共用同一入口；已配置DSN的正式包在编译前先检查固定CLI和上传凭据。
SENTRY_ARGS=(--platform "${PLATFORM}" --flavor "${FLAVOR}" --product-version "${VERSION_NAME}"
  --build-number "${BUILD_NUMBER}" --source-revision "$(git rev-parse HEAD)")
[ "${NO_SENTRY}" = "0" ] || SENTRY_ARGS+=(--no-sentry)
[ "${AUDIT_ONLY}" = "0" ] || SENTRY_ARGS+=(--audit-only)
run_sentry_postbuild "${SENTRY_ARGS[@]}" --preflight

echo "=== inject_desktop_brand（窗口标题 / 打包 display_name / 图标）==="
dart run tool/inject_desktop_brand.dart --flavor "${FLAVOR}" --platform "${PLATFORM}" --build-number "${BUILD_NUMBER}"

echo "=== generate desktop icons ==="
dart run flutter_launcher_icons -f flutter_launcher_icons.yaml

# ───────── Windows：先编 Go 核心取 CORE_SHA256（运行时核心完整性校验）─────────
if [ "${PLATFORM}" = "windows" ]; then
  echo "=== build Go core + CORE_SHA256（Windows）==="
  ( cd plugins/setup/buildkit/build_tool && dart pub get && dart run build_tool windows --root-dir "${REPO_DIR}" )
fi

# ───────── 合成 env.json（保住全部 XB_* defines；不走 setup.dart）─────────
APP_ENV=stable python3 tool/release_pipeline.py compose

# ───────── 激活 vendored flutter_distributor（经验 #4：不靠 PATH）─────────
echo "=== activate flutter_distributor ==="
python3 tool/distributor_preflight.py activate

# Shared target arguments and strict final package inventory.
python3 tool/record_build_environment.py --platform "${PLATFORM}"
python3 tool/release_pipeline.py package
python3 tool/record_build_environment.py --platform "${PLATFORM}"
python3 tool/release_pipeline.py normalize
python3 tool/check_fallback_assets.py

# ───────── Sentry：最终包匹配、伴随符号审计和上传，失败不报告完成 ─────────
NATIVE_ARCH="${ARCH}"
[ "${NATIVE_ARCH}" != "amd64" ] || NATIVE_ARCH=x64
run_sentry_postbuild "${SENTRY_ARGS[@]}" --architecture "${NATIVE_ARCH}"
python3 tool/release_pipeline.py verify

# ───────── 完成 ─────────
echo "=== done ==="
echo "  ${FLAVOR} 产品版本 v${VERSION_NAME} (build ${BUILD_NUMBER}) · 底座 ${BASE_VERSION} · ${PLATFORM}-${ARCH}"
echo "=== dist 产物 ==="
ls -la dist/ 2>/dev/null || echo "  (无 dist —— 检查上面打包日志)"
