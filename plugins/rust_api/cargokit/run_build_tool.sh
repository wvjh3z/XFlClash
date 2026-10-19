#!/usr/bin/env bash
set -euo pipefail
BASEDIR=$(cd "$(dirname "$0")" && pwd -P)
DART=dart
if [[ -n "${FLUTTER_ROOT:-}" ]]; then
  DART="$FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart"
fi
exec "$DART" "$BASEDIR/bootstrap.dart" "$@"
