## kernel/core/panic.sage — SageOS-RV Kernel Panic Handler
##
## Clean, verbose, and user-friendly kernel panic interface.
## Integrates with kernel/core/errors.sage for error codes and formatting.
##
## Provides:
##   panic(code)          — Fatal error with full diagnostic display, system halts
##   panic_with_msg(code, msg) — Fatal error with custom additional message
##   warn(code)           — Non-fatal warning, system continues
##   assert(cond, code)   — Condition check, panics if false
##   assert_not_null(val, code) — Null check, panics if nil

let PANIC_VERSION = "1.0.0"

proc panic(code):
    print("\n")
    print("╔══════════════════════════════════════════════════════╗\n")
    print("║              *** KERNEL PANIC ***                    ║\n")
    print("║                                                      ║\n")
    print("║  The SageOS-RV kernel has encountered a fatal error  ║\n")
    print("║  and cannot continue execution.                      ║\n")
    print("╚══════════════════════════════════════════════════════╝\n")
    print("\n")
    print("  ─── Diagnostic Information ───\n")
    print("\n")
    print("  Error Code:     0x")
    print(code)
    print("\n")
    print("  Subsystem:       ")
    print(panic_subsystem(code))
    print("\n")
    print("  Severity:        FATAL (System Halt)\n")
    print("\n")
    print("  Description:     ")
    print(panic_description(code))
    print("\n")
    print("  Suggested Fix:   ")
    print(panic_suggestion(code))
    print("\n")
    print("\n")
    print("  ─── System State ───\n")
    print("    Kernel:        SageOS-RV v0.2.0\n")
    print("    Architecture:  RISC-V 64 (rv64imac)\n")
    print("    VM Engine:     MetalRV64 (Q32.32 fixed-point)\n")
    print("    Board:         QEMU virt / LicheeRV Nano\n")
    print("    Panic Handler: v")
    print(PANIC_VERSION)
    print("\n")
    print("\n")
    print("  ─── Recovery ───\n")
    print("    This is an unrecoverable error. The system must be\n")
    print("    restarted. If this error persists:\n")
    print("    1. Rebuild with:  ./sagemake clean && ./sagemake build\n")
    print("    2. Verify hardware configuration.\n")
    print("    3. Report at: github.com/Night-Traders-Dev/SageOS-RV/issues\n")
    print("\n")
    print("════════════════════════════════════════════════════════\n")
    print("  SYSTEM HALTED — All processors stopped.\n")
    print("════════════════════════════════════════════════════════\n")

proc panic_with_msg(code, msg):
    print("\n")
    print("╔══════════════════════════════════════════════════════╗\n")
    print("║              *** KERNEL PANIC ***                    ║\n")
    print("╚══════════════════════════════════════════════════════╝\n")
    print("\n")
    print("  Error: 0x")
    print(code)
    print("\n")
    print("  Message: ")
    print(msg)
    print("\n")
    print("\n")
    print("  SYSTEM HALTED.\n")

proc warn(code):
    print("\n")
    print("  [WARNING] Subsystem ")
    print(panic_subsystem(code))
    print(" reported error 0x")
    print(code)
    print(": ")
    print(panic_description(code))
    print("\n")
    print("  Suggestion: ")
    print(panic_suggestion(code))
    print("\n\n")

proc assert(condition, code):
    if condition:
        return
    panic(code)

proc assert_not_null(value, code):
    if value != nil:
        return
    panic(code)

## --- Error code descriptions ---

proc panic_description(code):
    if code == 0x1001:
        return "Kernel boot sequence failed"
    if code == 0x1002:
        return "Kernel initialization failed"
    if code == 0x1003:
        return "Kernel assertion check failed"
    if code == 0x2001:
        return "Virtual machine failed to load bytecode blob"
    if code == 0x2002:
        return "Virtual machine execution error"
    if code == 0x2003:
        return "Virtual machine call stack overflow"
    if code == 0x2005:
        return "Virtual machine encountered invalid opcode"
    if code == 0x2006:
        return "Virtual machine out of memory"
    if code == 0x2007:
        return "Division by zero in virtual machine"
    if code == 0x3001:
        return "Physical memory allocation failed"
    if code == 0x3002:
        return "Out of physical memory pages"
    if code == 0x4001:
        return "UART 16550A initialization failed"
    if code == 0x7001:
        return "Virtual memory (VMM) initialization failed"
    if code == 0x8001:
        return "Shell initialization failed"
    if code == 0x8002:
        return "Failed to load shell bytecode blob"
    if code == 0x8003:
        return "Shell bytecode magic number mismatch"
    if code == 0x9001:
        return "SageRTOS scheduler initialization failed"
    if code == 0x9002:
        return "SageRTOS task execution failed"
    if code == 0xA001:
        return "SRVM module load failed"
    if code == 0xA002:
        return "SRVM runtime execution error"
    return "Unknown error condition"

proc panic_suggestion(code):
    let base = code & 0xF000
    if base == 0x1000:
        return "Check bootloader and kernel image. Rebuild with ./sagemake build."
    if base == 0x2000:
        return "Rebuild .sgvm blobs with ./sagemake build. Check VM pool sizes in metal_vm.h."
    if base == 0x3000:
        return "Increase PMM arena size or check for memory leaks."
    if base == 0x4000:
        return "Verify UART MMIO base address is correct for the target board."
    if base == 0x5000:
        return "Check SBI timer extension availability."
    if base == 0x6000:
        return "Verify DTB address and magic number."
    if base == 0x7000:
        return "Check SV39 page table setup and PMM availability."
    if base == 0x8000:
        return "Check shell.sage compilation and blob embedding."
    if base == 0x9000:
        return "Check SageRTOS task registration and scheduler configuration."
    if base == 0xA000:
        return "Run ./sagemake setup-srvm and rebuild."
    if base == 0xB000:
        return "Check driver source and MMIO configuration."
    return "Rebuild the kernel and verify hardware configuration."

proc panic_subsystem(code):
    let base = code & 0xF000
    if base == 0x1000:
        return "KERNEL"
    if base == 0x2000:
        return "VM"
    if base == 0x3000:
        return "MEMORY"
    if base == 0x4000:
        return "UART"
    if base == 0x5000:
        return "TIMER"
    if base == 0x6000:
        return "DTB"
    if base == 0x7000:
        return "VMM"
    if base == 0x8000:
        return "SHELL"
    if base == 0x9000:
        return "RTOS"
    if base == 0xA000:
        return "SRVM"
    if base == 0xB000:
        return "DRIVER"
    return "UNKNOWN"
