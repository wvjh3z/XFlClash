#!/usr/bin/env bash
# Local brand Android APK entry. This script never publishes a download site.
# Usage: source /path/to/android-env.sh
#        bash scripts/build_local.sh release arm64 brand_a [--batch-dir /protected/batch]
# Default release: production config, strict locks, clean build, original signing,
# verified APK/AOT and automatically prepared/audited/uploaded Sentry symbols.
# Only explicit --audit-only / --no-sentry create diagnostic output; diagnostic
# runs leave the successful release counter unchanged.
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "${REPO_DIR}/tool/build_android_local.py" "$@"
