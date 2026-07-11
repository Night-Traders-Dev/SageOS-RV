#!/usr/bin/env bash
## tests/shell_test.sh — Automated interactive shell test
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

PASS=0; FAIL=0
GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'; RESET='\033[0m'

assert_contains() { if echo "$OUTPUT" | grep -qF "$2"; then printf "  ${GREEN}[PASS]${RESET} %s\n" "$1"; PASS=$((PASS+1)); else printf "  ${RED}[FAIL]${RESET} %s\n" "$1"; FAIL=$((FAIL+1)); fi; }

printf "${CYAN}[BUILD]${RESET} Compiling...\n"
./sagemake build 2>&1 | grep -q "Build complete" || { echo "BUILD FAILED"; exit 1; }

printf "${CYAN}[TEST]${RESET} Launching QEMU...\n"
(sleep 12; echo "hello"; sleep 0.5; echo "world"; sleep 0.5; echo "foo"; sleep 2; echo "exit") | timeout 25 ./sagemake qemu 2>/dev/null > /tmp/sageos_test_out.txt || true
OUTPUT=$(cat /tmp/sageos_test_out.txt)

echo ""
printf "${CYAN}[CHECK]${RESET} Validating...\n"
assert_contains "Banner"           "SageOS-RV"
assert_contains "Shell prompt"     "sage#"
assert_contains "Input: hello"     "hello"
assert_contains "Input: world"     "world"
assert_contains "Input: foo"       "foo"

echo ""
printf "${CYAN}[SUMMARY]${RESET} Tests: $((PASS + FAIL)) | ${GREEN}Passed: $PASS${RESET} | ${RED}Failed: $FAIL${RESET}\n"
[ "$FAIL" -eq 0 ] && echo "ALL TESTS PASSED" && exit 0 || exit 1
