#!/usr/bin/env bash
## tools/build_tools.sh — Compile all Sage tools to .sgvm binaries
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="$SCRIPT_DIR/tools/bin"
OUT_DIR="$SCRIPT_DIR/rootfs/bin"
mkdir -p "$OUT_DIR"

echo "Building Sage tools..."
for sage_file in "$BIN_DIR"/*.sage; do
    name=$(basename "$sage_file" .sage)
    out="$OUT_DIR/$name.sgvm"
    sagevm compile "$sage_file" "$out" --riscv 2>/dev/null && echo "  $name" || echo "  FAIL: $name"
done
echo "Done."
