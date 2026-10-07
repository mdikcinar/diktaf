#!/usr/bin/env bash
# Renders docs/mockups/*.html to docs/images/*.png for the README.
#
# Drawn rather than screenshotted, so the pictures can be regenerated after a
# change to the interface without anybody's desktop, data or permissions in them.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$(mktemp -d)/render-mockups"

swiftc -O -o "$BIN" "$DIR/Scripts/render-mockups.swift"
mkdir -p "$DIR/docs/images"
if [[ $# -eq 0 ]]; then set -- "$DIR"/docs/mockups/*.html; fi
"$BIN" "$DIR/docs/images" "$@"
