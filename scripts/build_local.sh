#!/usr/bin/env bash
# 本地构建脚本（形态 A / brand_a / MyClient）。规范见 .github/BUILD_AND_RELEASE.md。
#
# 用法:
#   bash scripts/build_local.sh release [arm64|x64]   # release APK（默认 arm64，真机分发）
#   bash scripts/build_local.sh debug                 # debug APK（全 ABI，模拟器用）
#
# 版本号（两套，不同来源）:
#   产品版本 versionName ← flavors/brand_a/flavor.yaml（如 0.0.1）；注入 XB_PRODUCT_VERSION，
#                          「我的」Tab 关于显示 v{版本}-{时间戳}（MyClient 自有，与底座脱钩）
#   底座版本 build-name  ← pubspec.yaml version（FlClash 0.8.93）；喂 packageInfo，
#                          设置→关于（原生 AboutView）显示底座版本，沿用上游不改
#   versionCode          ← scripts/build_number.txt，每次 release 构建自动 +1（Android 覆盖更新）
#   buildTag             ← 构建时间戳（YYYYMMDDHHMM），注入 XB_BUILD_TAG
#
# 特性: 清 Flutter 构建缓存（防 release AOT 复用陈旧 app.dill → 代码改动未编译进包）。
set -euo pipefail

MODE="${1:-release}"
ARCH="${2:-arm64}"

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

FLAVOR_YAML="flavors/brand_a/flavor.yaml"
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
)

echo "=== build: mode=$MODE arch=$ARCH ==="
echo "    productVersion=$VERSION_NAME  baseVersion(build-name)=$BASE_VERSION  versionCode=$BUILD_NUMBER  tag=$TAG"
echo "=== flutter clean（铁律：防 release AOT 复用陈旧 app.dill → 代码改动未编译进包）==="
flutter clean >/dev/null 2>&1 || true
flutter pub get >/dev/null 2>&1 || true

# === 本地自测：注入真实 AES key（防 flavor_defines.json 被 prepare_flavor 冲空致登录失败）===
# flavor.yaml 按设计不存密钥（D58），prepare_flavor 生成的 flavor_defines.json 里 XB_AES_KEY_B64 恒为空。
# 没有 key → bootstrap 无法解密 config.json → 拿不到真实 API → 登录打到 COS 桶报 MethodNotAllowed。
# 本地自测从 gitignored 的 .secrets/ 取回真实 key 注入；CI 环境无 .secrets，靠 CI secrets 注入。
SECRETS_FILE=".secrets/xboard-dev-secrets.md"
DEFINES_FILE="flavor_defines.json"
if [ ! -f "$DEFINES_FILE" ]; then
  echo "=== flavor_defines.json 不存在 → prepare_flavor 生成（test target，空 key 占位）==="
  dart run tool/prepare_flavor.dart --flavor brand_a --target test >/dev/null 2>&1 || true
fi
if [ -f "$SECRETS_FILE" ] && [ -f "$DEFINES_FILE" ]; then
  # 提取 .secrets 里的 32 字节 base64 主密钥（44 字符、末尾 '='；md 内仅此行匹配）。
  AES_KEY="$(grep -oE '^[A-Za-z0-9+/]{43}=$' "$SECRETS_FILE" | head -1)"
  if [ -n "$AES_KEY" ]; then
    python3 - "$DEFINES_FILE" "$AES_KEY" <<'PY'
import json, sys
path, key = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    d = json.load(f)
d["XB_AES_KEY_B64"] = key
with open(path, "w", encoding="utf-8") as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
    echo "=== ✓ 已从 .secrets 注入真实 AES key（本地自测，bootstrap 可解密）==="
  else
    echo "⚠ .secrets 未找到合法 AES key（44 字符 base64），沿用 flavor_defines.json 现值"
  fi
else
  echo "⚠ 无 .secrets（CI 环境？）→ XB_AES_KEY_B64 靠 CI secrets 注入"
fi

if [ "$MODE" = "release" ]; then
  case "$ARCH" in
    arm64) TP="android-arm64"; ABISUF="arm64-v8a" ;;
    x64)   TP="android-x64";   ABISUF="x86_64" ;;
    *) echo "未知 arch: $ARCH（用 arm64 或 x64）"; exit 1 ;;
  esac
  flutter build apk --release --flavor brand_a \
    "${COMMON_DEFINES[@]}" \
    --build-name="$BASE_VERSION" \
    --build-number="$BUILD_NUMBER" \
    --split-per-abi --target-platform "$TP"
  OUT="build/app/outputs/flutter-apk/app-${ABISUF}-brand_a-release.apk"
else
  flutter build apk --debug --flavor brand_a \
    "${COMMON_DEFINES[@]}" \
    --build-name="$BASE_VERSION" \
    --build-number="$BUILD_NUMBER"
  OUT="build/app/outputs/flutter-apk/app-brand_a-debug.apk"
fi

echo "=== done ==="
echo "  MyClient 产品版本 v$VERSION_NAME (build $BUILD_NUMBER) · 底座 $BASE_VERSION"
echo "  buildTag : $TAG"
echo "  apk      : $OUT"
ls -la "$OUT" 2>/dev/null || echo "  (产物未找到，检查上面构建日志)"
