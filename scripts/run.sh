#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIGURATION="${CONFIGURATION:-debug}"
./scripts/package.sh --dev
if pgrep -x HarnaisDev >/dev/null 2>&1; then
  killall HarnaisDev 2>/dev/null || true
  for _ in {1..40}; do
    if ! pgrep -x HarnaisDev >/dev/null 2>&1; then
      break
    fi
    sleep 0.05
  done
fi
open "dist/Harnais Dev.app"
