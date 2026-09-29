#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c debug --product HarnaisTests
BIN="$(swift build -c debug --show-bin-path)/HarnaisTests"
exec "$BIN"
