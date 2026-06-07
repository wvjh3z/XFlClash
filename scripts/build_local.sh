#!/usr/bin/env bash
# 本地构建脚本（形态 A / brand_a）。规范见 .github/BUILD_AND_RELEASE.md。
#
# 用法:
#   bash scripts/build_local.sh release [arm64|x64]   # release APK（默认 arm64）
#   bash scripts/build_local.sh debug                 # debug APK（全 ABI，模拟器用）
#
# 特性:
#   - 清 Flutter 构建缓存（避免 release AOT 复用陈旧 app.dill → 代码改动未编译进包）
#   - 注入 buildTag（关于页可核对安装的是否目标构建）
#   - versionName/versionCode 来自 pubspec.yaml（单一事实来源）；本地构建不改 versionCode
set -euo pipefail

MODE="${1:-release}"
ARCH="${2:-arm64}"

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

# buildTag：本地用 短SHA + 时间戳（CI 另行注入）。
SHA="$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"
TAG="local-$(date +%Y%m%d-%H%M)-$SHA"

COMMON_DEFINES=(
  --dart-define-from-file=flavor_defines.json
  --dart-define=XB_FORM_A=true
  --dart-define=XB_BUILD_TAG="$TAG"
)

echo "=== build: mode=$MODE arch=$ARCH tag=$TAG ==="
echo "=== 清 Flutter 构建缓存（铁律：防 release 复用陈旧产物）==="
rm -rf .dart_tool/flutter_build build/app/intermediates/flutter 2>/dev/null || true

if [ "$MODE" = "release" ]; then
  case "$ARCH" in
    arm64) TP="android-arm64"; ABISUF="arm64-v8a" ;;
    x64)   TP="android-x64";   ABISUF="x86_64" ;;
    *) echo "未知 arch: $ARCH（用 arm64 或 x64）"; exit 1 ;;
  esac
  flutter build apk --release --flavor brand_a \
    "${COMMON_DEFINES[@]}" \
    --split-per-abi --target-platform "$TP"
  OUT="build/app/outputs/flutter-apk/app-${ABISUF}-brand_a-release.apk"
else
  flutter build apk --debug --flavor brand_a "${COMMON_DEFINES[@]}"
  OUT="build/app/outputs/flutter-apk/app-brand_a-debug.apk"
fi

VN="$(grep -m1 '^version:' pubspec.yaml | sed 's/version:[[:space:]]*//')"
echo "=== done ==="
echo "  pubspec version : $VN"
echo "  buildTag        : $TAG"
echo "  apk             : $OUT"
ls -la "$OUT" 2>/dev/null || echo "  (产物未找到，检查上面构建日志)"
