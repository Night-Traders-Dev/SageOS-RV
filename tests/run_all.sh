#!/usr/bin/env bash
## tests/run_all.sh — Run all tests for SageOS-RV
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

PASS=0
FAIL=0

run_test() {
    local name="$1"
    local cmd="$2"
    echo -e "\n\033[0;36m[TEST]\033[0m Running $name..."
    if eval "$cmd"; then
        echo -e "  \033[0;32m[PASS]\033[0m $name"
        PASS=$((PASS+1))
    else
        echo -e "  \033[0;31m[FAIL]\033[0m $name"
        FAIL=$((FAIL+1))
    fi
}

echo "========================================"
echo "  SageOS-RV Comprehensive Test Suite"
echo "========================================"

# Compile all .sage tests
sagevm compile tests/driver_tests.sage --riscv >/dev/null 2>&1 || true
sagevm compile tests/wifi_tests.sage --riscv >/dev/null 2>&1 || true

# Run SageVM script tests natively
run_test "WiFi Driver Specifications" "/usr/local/bin/sage tests/wifi_tests.sage"
run_test "Hardware Driver Registers" "/usr/local/bin/sage tests/driver_tests.sage"

# Submodule tests
run_test "SageFS B-Tree Component Tests" "(cd fs/sagefs && ./sagemake test)"
run_test "SageSMP Mailbox & Node Tests" "(cd kernel/smp && ./sagemake --test)"

# QEMU Python Tests
run_test "QEMU Kernel Boot (C-Only)" "python3 tests/qemu_test.py c-only"
run_test "QEMU Kernel Boot (SageVM)" "python3 tests/qemu_test.py sagevm"

# Interactive Shell Test
run_test "Interactive Shell Integration" "bash tests/shell_test.sh"

echo ""
echo "========================================"
echo -e "  \033[0;36mTest Summary\033[0m"
echo "========================================"
echo -e "  \033[0;32mPassed:\033[0m $PASS"
echo -e "  \033[0;31mFailed:\033[0m $FAIL"
echo "========================================"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
