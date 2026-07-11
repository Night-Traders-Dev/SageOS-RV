#!/usr/bin/env bash
## tools/gen_ssh.sh — Build the self-contained ssh command.
##
## Concatenates the import-free TCP/IP stack (kernel/net/tcp_stack.sage)
## with the ssh command logic (tools/bin/ssh_main.sage) into
## tools/bin/ssh.sage.  build_tools.sh then compiles that to
## rootfs/bin/ssh.sgvm.  The embedded RV64 VM has no import support, so the
## stack must be inlined.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STACK="$SCRIPT_DIR/kernel/net/tcp_stack.sage"
MAIN="$SCRIPT_DIR/tools/bin/ssh_main.sage"
OUT="$SCRIPT_DIR/tools/bin/ssh.sage"

cat "$STACK" "$MAIN" > "$OUT"
echo "Generated $OUT ($(wc -l < "$OUT") lines)"
