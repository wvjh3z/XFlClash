#!/usr/bin/env bash
# 本地构建脚本（形态 A，多品牌）。规范见 .github/BUILD_AND_RELEASE.md。
#
# 用法:
#   bash scripts/build_local.sh release [arm64|x64] [flavor]   # release APK（默认 arm64 / brand_a）
#   bash scripts/build_local.sh debug   [arch]      [flavor]   # debug APK
#   例：bash scripts/build_local.sh release arm64 brand_b
#   flavor 默认 brand_a（保持旧行为）；可选 brand_a / brand_b。
#
# 版本号（两套，不同来源）:
#   产品版本 versionName ← flavors/<flavor>/flavor.yaml（如 0.0.1）；注入 XB_PRODUCT_VERSION，
#                          「我的」Tab 关于显示 v{版本}-{时间戳}（自有，与底座脱钩）
#   底座版本 build-name  ← pubspec.yaml version（FlClash 0.8.93）；喂 packageInfo，
#                          设置→关于（原生 AboutView）显示底座版本，沿用上游不改
#   versionCode          ← scripts/build_number.txt，每次 release 构建自动 +1（Android 覆盖更新）
#   buildTag             ← 构建时间戳（YYYYMMDDHHMM），注入 XB_BUILD_TAG
#
# 特性: 清 Flutter 构建缓存（防 release AOT 复用陈旧 app.dill → 代码改动未编译进包）。
set -euo pipefail

MODE="${1:-release}"
ARCH="${2:-arm64}"
FLAVOR="${3:-brand_a}"

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

FLAVOR_YAML="flavors/${FLAVOR}/flavor.yaml"
[ -f "$FLAVOR_YAML" ] || { echo "✗ 找不到 flavor 配置：$FLAVOR_YAML"; exit 1; }
BUILD_NUM_FILE="scripts/build_number.txt"

# 产品版本名（MyClient 自有，注入 dart-define 供「我的」Tab 关于显示 v{版本}-{时间戳}）
VERSION_NAME="$(grep -m1 -E '^\s*versionName:' "$FLAVOR_YAML" | sed -E 's/.*versionName:\s*"?([^"#]+)"?.*/\1/' | xargs)"
[ -n "$VERSION_NAME" ] || { echo "✗ 未能从 $FLAVOR_YAML 读到 versionName"; exit 1; }

# build-name = FlClash 底座版本：喂 packageInfo → 设置「关于」(原生 AboutView) 显示底座版本，沿用上游。
# 取自 pubspec.yaml 的 version 字段（如 0.8.93+2026052901 → 0.8.93）。
BASE_VERSION="$(grep -m1 -E '^version:' pubspec.yaml | sed -E 's/^version:\s*([0-9.]+).*/\1/' | xargs)"
[ -n "$BASE_VERSION" ] || BASE_VERSION="0.8.93"

# versionCode：debug 不动计数（沿用当前值）；release 自增并写回。
BUILD_NUMBER="$(cat "$BUILD_NUM_FILE" 2>/dev/null || echo 1)"
if [ "$MODE" = "release" ]; then
  BUILD_NUMBER=$((BUILD_NUMBER + 1))
  echo "$BUILD_NUMBER" > "$BUILD_NUM_FILE"
fi

SHA="$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"
# buildTag = 构建时间戳（YYYYMMDDHHMM）。关于页显示 v{versionName}-{时间戳}，简洁有意义、
# 每次构建必变（核对编译产物是否最新）。versionCode(整数)仍由 build_number.txt 维护,内部用。
TAG="$(date +%Y%m%d%H%M)"

COMMON_DEFINES=(
  --dart-define-from-file=flavor_defines.json
  --dart-define=XB_FORM_A=true
  --dart-define=XB_BUILD_TAG="$TAG"
  --dart-define=XB_PRODUCT_VERSION="$VERSION_NAME"
  --dart-define=XB_BUILD_NUMBER="$BUILD_NUMBER"
)

echo "=== build: mode=$MODE arch=$ARCH ==="
echo "    productVersion=$VERSION_NAME  baseVersion(build-name)=$BASE_VERSION  versionCode=$BUILD_NUMBER  tag=$TAG"
echo "=== flutter clean（铁律：防 release AOT 复用陈旧 app.dill → 代码改动未编译进包）==="
flutter clean >/dev/null 2>&1 || true
flutter pub get >/dev/null 2>&1 || true

# === flavor_defines.json 生成（含 AES key）===
# 本地：aesKey 直接存 flavors/<flavor>/flavor.yaml（已 gitignored），prepare_flavor 读它生成
# 非空 XB_AES_KEY_B64，无需 .secrets 注入。缺/错 key → bootstrap 解不开 config.json → 登录打到
# COS 桶报 MethodNotAllowed。
# 注：CI（release-build.yml）也走 flavor.yaml（方案 A）：aesKey + Android 签名均内嵌其中，
#     无需额外 GitHub secret，与本脚本单一来源一致。
# 出厂 fallback 直接打包 flavors/<flavor>/assets/fallback.bin（pubspec 已声明），无需拷贝。
# release 额外 --android-signing：从 flavor.yaml 的 androidSigning 块落地 keystore.jks +
#   local.properties 签名行（与 CI 单一来源一致）。debug 走 debug 签名，不需要。
echo "=== prepare_flavor：生成 flavor_defines.json（含 aesKey）==="
SIGN_FLAG=""
[ "$MODE" = "release" ] && SIGN_FLAG="--android-signing"
dart run tool/prepare_flavor.dart --flavor "$FLAVOR" --target test $SIGN_FLAG || true

if [ "$MODE" = "release" ]; then
  case "$ARCH" in
    arm64) TP="android-arm64"; ABISUF="arm64-v8a" ;;
    x64)   TP="android-x64";   ABISUF="x86_64" ;;
    *) echo "未知 arch: $ARCH（用 arm64 或 x64）"; exit 1 ;;
  esac
  # 限定单一 ABI（build.gradle.kts 读 local.properties 的 XB_TARGET_ABI → abiFilters）：不 split
  # 也只打这一个 ABI，versionCode 因此不被偏移，等于 build-number。用 local.properties 传值而非 env
  # （gradle 守护进程 env 陈旧）；构建后（含失败）经 trap 移除，避免污染 IDE / flutter run 的多 ABI。
  LP="$REPO_DIR/android/local.properties"
  sed -i '/^XB_TARGET_ABI=/d' "$LP"
  echo "XB_TARGET_ABI=$ABISUF" >> "$LP"
  trap 'sed -i "/^XB_TARGET_ABI=/d" "$LP"' EXIT
  flutter build apk --release --flavor "$FLAVOR" \
    "${COMMON_DEFINES[@]}" \
    --build-name="$BASE_VERSION" \
    --build-number="$BUILD_NUMBER" \
    --target-platform "$TP"
  # 单一 ABI 包（不 --split-per-abi）→ versionCode 不被 abi 偏移，等于 build-number（自分发侧载用）。
  OUT="build/app/outputs/flutter-apk/app-${FLAVOR}-release.apk"
else
  flutter build apk --debug --flavor "$FLAVOR" \
    "${COMMON_DEFINES[@]}" \
    --build-name="$BASE_VERSION" \
    --build-number="$BUILD_NUMBER"
  OUT="build/app/outputs/flutter-apk/app-${FLAVOR}-debug.apk"
fi

echo "=== done ==="
echo "  MyClient 产品版本 v$VERSION_NAME (build $BUILD_NUMBER) · 底座 $BASE_VERSION"
echo "  buildTag : $TAG"
echo "  apk      : $OUT"
ls -la "$OUT" 2>/dev/null || echo "  (产物未找到，检查上面构建日志)"

# === 自动部署到 nginx 下载站（仅 brand_a release arm64）===
# nginx 监听 8080，root=/www/wwwroot/apkdl，开机自启、进程稳定（替代易挂的 python http.server）。
# 下载 URL：http://147.135.105.62:8080/MyClient-{versionName}-android-arm64-v8a.apk（插件命名规则）。
# ⚠️ 此部署是 brand_a 专属基建（固定服务器 + 命名规则匹配 brand_a 应用内更新器），其他 flavor 不部署。
if [ "$MODE" = "release" ] && [ "$ARCH" = "arm64" ] && [ "$FLAVOR" = "brand_a" ]; then
  DEPLOY_DIR="/www/wwwroot/apkdl"
  DEPLOY_NAME="MyClient-${VERSION_NAME}-android-arm64-v8a.apk"
  if [ -f "$OUT" ] && [ -d "$DEPLOY_DIR" ]; then
    cp "$OUT" "$DEPLOY_DIR/$DEPLOY_NAME"
    chown www:www "$DEPLOY_DIR/$DEPLOY_NAME" 2>/dev/null || true
    SHA256="$(sha256sum "$DEPLOY_DIR/$DEPLOY_NAME" | cut -d' ' -f1)"
    echo "=== ✓ 已部署到 nginx 下载站 ==="
    echo "  路径   : $DEPLOY_DIR/$DEPLOY_NAME"
    echo "  URL    : http://147.135.105.62:8080/$DEPLOY_NAME"
    echo "  sha256 : $SHA256"
    echo "  → 后台配置 version_code=$BUILD_NUMBER + android_arm64_sha256=$SHA256，然后 octane:reload"
  else
    echo "⚠ 跳过 nginx 部署（产物或目录不存在：$DEPLOY_DIR）"
  fi
fi
