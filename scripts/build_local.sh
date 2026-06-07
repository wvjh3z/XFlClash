#!/usr/bin/env bash
# 本地构建脚本（形态 A / brand_a / MyClient）。规范见 .github/BUILD_AND_RELEASE.md。
#
# 用法:
#   bash scripts/build_local.sh release [arm64|x64]   # release APK（默认 arm64，真机分发）
#   bash scripts/build_local.sh debug                 # debug APK（全 ABI，模拟器用）
#
# 版本号（与 FlClash 底座脱钩，MyClient 自有产品版本）:
#   versionName  ← flavors/brand_a/flavor.yaml 的 versionName（如 0.1.0），功能发布手动递增
#   versionCode  ← scripts/build_number.txt，每次 release 构建自动 +1（单调递增,Android 覆盖更新正常）
#   buildTag     ← 自动 = v{versionName}-build{N}-{短SHA}（关于页核对安装的是否目标构建）
#
# 特性: 清 Flutter 构建缓存（防 release AOT 复用陈旧 app.dill → 代码改动未编译进包）。
set -euo pipefail

MODE="${1:-release}"
ARCH="${2:-arm64}"

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

FLAVOR_YAML="flavors/brand_a/flavor.yaml"
BUILD_NUM_FILE="scripts/build_number.txt"

# 产品版本名（从 flavor.yaml 读，MyClient 自有，非 FlClash 0.8.93）
VERSION_NAME="$(grep -m1 -E '^\s*versionName:' "$FLAVOR_YAML" | sed -E 's/.*versionName:\s*"?([^"#]+)"?.*/\1/' | xargs)"
[ -n "$VERSION_NAME" ] || { echo "✗ 未能从 $FLAVOR_YAML 读到 versionName"; exit 1; }

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
)

echo "=== build: mode=$MODE arch=$ARCH ==="
echo "    versionName=$VERSION_NAME  versionCode=$BUILD_NUMBER  tag=$TAG"
echo "=== flutter clean（铁律：防 release AOT 复用陈旧 app.dill → 代码改动未编译进包）==="
flutter clean >/dev/null 2>&1 || true
flutter pub get >/dev/null 2>&1 || true

if [ "$MODE" = "release" ]; then
  case "$ARCH" in
    arm64) TP="android-arm64"; ABISUF="arm64-v8a" ;;
    x64)   TP="android-x64";   ABISUF="x86_64" ;;
    *) echo "未知 arch: $ARCH（用 arm64 或 x64）"; exit 1 ;;
  esac
  flutter build apk --release --flavor brand_a \
    "${COMMON_DEFINES[@]}" \
    --build-name="$VERSION_NAME" \
    --build-number="$BUILD_NUMBER" \
    --split-per-abi --target-platform "$TP"
  OUT="build/app/outputs/flutter-apk/app-${ABISUF}-brand_a-release.apk"
else
  flutter build apk --debug --flavor brand_a \
    "${COMMON_DEFINES[@]}" \
    --build-name="$VERSION_NAME" \
    --build-number="$BUILD_NUMBER"
  OUT="build/app/outputs/flutter-apk/app-brand_a-debug.apk"
fi

echo "=== done ==="
echo "  MyClient v$VERSION_NAME (build $BUILD_NUMBER)"
echo "  buildTag : $TAG"
echo "  apk      : $OUT"
ls -la "$OUT" 2>/dev/null || echo "  (产物未找到，检查上面构建日志)"
