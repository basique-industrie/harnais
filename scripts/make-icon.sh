#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
OUT="$ROOT/Sources/HarnaisCore/Resources"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/Harnais-icon.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$OUT" "$STAGE/Harnais.iconset"
swift "$ROOT/scripts/render-icon.swift" "$STAGE/Harnais.iconset"
iconutil -c icns "$STAGE/Harnais.iconset" -o "$OUT/Harnais.icns"
echo "Wrote $OUT/Harnais.icns"
