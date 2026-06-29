## kernel/core/errors.sage — SageOS-RV Error Handling System
##
## Provides a comprehensive, hierarchical error type system with
## severity levels, error codes, and formatted error reporting.
##
## Architecture:
##   Error types are organized by subsystem (KERNEL, VM, MEMORY, UART, etc.)
##   Each error carries a numeric code, severity, message, and suggestion.
##   panic() provides a verbose, user-friendly crash display.

## --- Error Severity Levels ---

let ERROR_FATAL   = 0    ## System must halt immediately
let ERROR_CRITICAL = 1  ## Subsystem failure, degraded operation
let ERROR_WARNING  = 2  ## Non-fatal issue, system continues
let ERROR_INFO     = 3  ## Informational diagnostic

## --- Subsystem Codes ---

let SUBSYS_KERNEL    = 0x1000
let SUBSYS_VM        = 0x2000
let SUBSYS_MEMORY    = 0x3000
let SUBSYS_UART      = 0x4000
let SUBSYS_TIMER     = 0x5000
let SUBSYS_DTB       = 0x6000
let SUBSYS_VMM       = 0x7000
let SUBSYS_SHELL     = 0x8000
let SUBSYS_RTOS      = 0x9000
let SUBSYS_SRVM      = 0xA000
let SUBSYS_DRIVER    = 0xB000

## --- Error Code Ranges by Subsystem ---

## KERNEL (0x1000-0x1FFF)
let ERR_KERNEL_BOOT_FAILED      = SUBSYS_KERNEL + 1
let ERR_KERNEL_INIT_FAILED      = SUBSYS_KERNEL + 2
let ERR_KERNEL_ASSERT_FAILED    = SUBSYS_KERNEL + 3
let ERR_KERNEL_UNREACHABLE      = SUBSYS_KERNEL + 4

## VM (0x2000-0x2FFF)
let ERR_VM_LOAD_FAILED          = SUBSYS_VM + 1
let ERR_VM_EXEC_FAILED          = SUBSYS_VM + 2
let ERR_VM_STACK_OVERFLOW       = SUBSYS_VM + 3
let ERR_VM_STACK_UNDERFLOW      = SUBSYS_VM + 4
let ERR_VM_INVALID_OPCODE       = SUBSYS_VM + 5
let ERR_VM_OUT_OF_MEMORY        = SUBSYS_VM + 6
let ERR_VM_DIVISION_BY_ZERO     = SUBSYS_VM + 7

## MEMORY (0x3000-0x3FFF)
let ERR_MEM_ALLOC_FAILED        = SUBSYS_MEMORY + 1
let ERR_MEM_OUT_OF_PAGES        = SUBSYS_MEMORY + 2
let ERR_MEM_CORRUPTION          = SUBSYS_MEMORY + 3
let ERR_MEM_INVALID_ADDRESS     = SUBSYS_MEMORY + 4

## UART (0x4000-0x4FFF)
let ERR_UART_INIT_FAILED        = SUBSYS_UART + 1
let ERR_UART_READ_FAILED        = SUBSYS_UART + 2
let ERR_UART_WRITE_FAILED       = SUBSYS_UART + 3
let ERR_UART_OVERRUN            = SUBSYS_UART + 4

## TIMER (0x5000-0x5FFF)
let ERR_TIMER_INIT_FAILED       = SUBSYS_TIMER + 1
let ERR_TIMER_EXPIRED           = SUBSYS_TIMER + 2

## DTB (0x6000-0x6FFF)
let ERR_DTB_PARSE_FAILED        = SUBSYS_DTB + 1
let ERR_DTB_MAGIC_MISMATCH      = SUBSYS_DTB + 2

## VMM (0x7000-0x7FFF)
let ERR_VMM_INIT_FAILED         = SUBSYS_VMM + 1
let ERR_VMM_PAGE_FAULT          = SUBSYS_VMM + 2
let ERR_VMM_INVALID_MAPPING     = SUBSYS_VMM + 3

## SHELL (0x8000-0x8FFF)
let ERR_SHELL_INIT_FAILED       = SUBSYS_SHELL + 1
let ERR_SHELL_LOAD_FAILED       = SUBSYS_SHELL + 2
let ERR_SHELL_MAGIC_MISMATCH    = SUBSYS_SHELL + 3
let ERR_SHELL_COMMAND_FAILED    = SUBSYS_SHELL + 4

## RTOS (0x9000-0x9FFF)
let ERR_RTOS_INIT_FAILED        = SUBSYS_RTOS + 1
let ERR_RTOS_TASK_FAILED        = SUBSYS_RTOS + 2
let ERR_RTOS_DEADLOCK           = SUBSYS_RTOS + 3

## SRVM (0xA000-0xAFFF)
let ERR_SRVM_LOAD_FAILED        = SUBSYS_SRVM + 1
let ERR_SRVM_RUNTIME_ERROR      = SUBSYS_SRVM + 2

## DRIVER (0xB000-0xBFFF)
let ERR_DRIVER_LOAD_FAILED      = SUBSYS_DRIVER + 1
let ERR_DRIVER_MMIO_FAULT       = SUBSYS_DRIVER + 2

## --- Error Type Registry ---
##
## Maps error codes to human-readable descriptions and suggested actions.

proc get_error_info(code):
    if code == ERR_KERNEL_BOOT_FAILED:
        return {message: "Kernel boot sequence failed", suggestion: "Check bootloader configuration and kernel image integrity.", severity: ERROR_FATAL}
    if code == ERR_KERNEL_INIT_FAILED:
        return {message: "Kernel initialization failed", suggestion: "Verify hardware configuration and memory layout.", severity: ERROR_FATAL}
    if code == ERR_KERNEL_ASSERT_FAILED:
        return {message: "Kernel assertion failed", suggestion: "This is an internal consistency check failure. Report to developers.", severity: ERROR_FATAL}
    if code == ERR_KERNEL_UNREACHABLE:
        return {message: "Reached unreachable code path", suggestion: "This indicates a logic error in the kernel. Report to developers.", severity: ERROR_FATAL}
    if code == ERR_VM_LOAD_FAILED:
        return {message: "Virtual machine failed to load bytecode", suggestion: "Verify that the .sgvm blob is correctly embedded in the kernel image.", severity: ERROR_FATAL}
    if code == ERR_VM_EXEC_FAILED:
        return {message: "Virtual machine execution failed", suggestion: "Check VM error message for details on the failing instruction.", severity: ERROR_FATAL}
    if code == ERR_VM_STACK_OVERFLOW:
        return {message: "Virtual machine stack overflow", suggestion: "Increase VM stack size or reduce recursion depth in Sage code.", severity: ERROR_FATAL}
    if code == ERR_VM_STACK_UNDERFLOW:
        return {message: "Virtual machine stack underflow", suggestion: "This indicates a VM internal error. Report to developers.", severity: ERROR_FATAL}
    if code == ERR_VM_INVALID_OPCODE:
        return {message: "Virtual machine encountered invalid opcode", suggestion: "The bytecode may be corrupted. Rebuild with sagevm compile --riscv.", severity: ERROR_FATAL}
    if code == ERR_VM_OUT_OF_MEMORY:
        return {message: "Virtual machine out of memory", suggestion: "Increase VM pool sizes in metal_vm.h configuration.", severity: ERROR_FATAL}
    if code == ERR_VM_DIVISION_BY_ZERO:
        return {message: "Division by zero in virtual machine", suggestion: "Check Sage code for division by zero in arithmetic expressions.", severity: ERROR_FATAL}
    if code == ERR_MEM_ALLOC_FAILED:
        return {message: "Memory allocation failed", suggestion: "System is out of physical memory. Reduce memory usage or increase RAM.", severity: ERROR_CRITICAL}
    if code == ERR_MEM_OUT_OF_PAGES:
        return {message: "Out of physical memory pages", suggestion: "Increase PMM arena size in fallback_kernel.c.", severity: ERROR_CRITICAL}
    if code == ERR_MEM_CORRUPTION:
        return {message: "Memory corruption detected", suggestion: "Check for buffer overflows or use-after-free in kernel code.", severity: ERROR_FATAL}
    if code == ERR_MEM_INVALID_ADDRESS:
        return {message: "Invalid memory address accessed", suggestion: "Verify MMIO base addresses and memory map layout.", severity: ERROR_FATAL}
    if code == ERR_UART_INIT_FAILED:
        return {message: "UART initialization failed", suggestion: "Verify UART base address and that the 16550A controller is present.", severity: ERROR_FATAL}
    if code == ERR_UART_READ_FAILED:
        return {message: "UART read operation failed", suggestion: "Check UART line status register and hardware connection.", severity: ERROR_WARNING}
    if code == ERR_UART_WRITE_FAILED:
        return {message: "UART write operation failed", suggestion: "Check UART transmitter and line status.", severity: ERROR_CRITICAL}
    if code == ERR_UART_OVERRUN:
        return {message: "UART receive buffer overrun", suggestion: "Increase UART FIFO depth or process input faster.", severity: ERROR_WARNING}
    if code == ERR_TIMER_INIT_FAILED:
        return {message: "Timer initialization failed", suggestion: "Check SBI timer extension availability and stimecmp CSR access.", severity: ERROR_CRITICAL}
    if code == ERR_TIMER_EXPIRED:
        return {message: "Timer expired unexpectedly", suggestion: "This may indicate a missed deadline. Check timer configuration.", severity: ERROR_WARNING}
    if code == ERR_DTB_PARSE_FAILED:
        return {message: "Device tree blob parsing failed", suggestion: "Verify DTB address and magic number. Use qemu -dtb to provide a valid DTB.", severity: ERROR_CRITICAL}
    if code == ERR_DTB_MAGIC_MISMATCH:
        return {message: "Device tree blob magic number mismatch", suggestion: "The DTB is corrupted or not present. Expected magic: 0xD00DFEED.", severity: ERROR_CRITICAL}
    if code == ERR_VMM_INIT_FAILED:
        return {message: "Virtual memory manager initialization failed", suggestion: "Check SV39 page table setup and PMM availability.", severity: ERROR_FATAL}
    if code == ERR_VMM_PAGE_FAULT:
        return {message: "Virtual memory page fault", suggestion: "Access to an unmapped virtual address. Check memory mappings.", severity: ERROR_FATAL}
    if code == ERR_VMM_INVALID_MAPPING:
        return {message: "Invalid virtual memory mapping requested", suggestion: "Check virtual/physical address alignment and page table flags.", severity: ERROR_FATAL}
    if code == ERR_SHELL_INIT_FAILED:
        return {message: "Shell initialization failed", suggestion: "Check shell.sgvm blob integrity and VM configuration.", severity: ERROR_CRITICAL}
    if code == ERR_SHELL_LOAD_FAILED:
        return {message: "Failed to load shell bytecode", suggestion: "Rebuild with ./sagemake build. Verify shell/shell.sage compiles successfully.", severity: ERROR_CRITICAL}
    if code == ERR_SHELL_MAGIC_MISMATCH:
        return {message: "Shell bytecode magic number mismatch", suggestion: "The embedded shell.sgvm blob may be corrupted. Rebuild with ./sagemake build.", severity: ERROR_FATAL}
    if code == ERR_SHELL_COMMAND_FAILED:
        return {message: "Shell command execution failed", suggestion: "Check command syntax. Type 'help' for available commands.", severity: ERROR_WARNING}
    if code == ERR_RTOS_INIT_FAILED:
        return {message: "SageRTOS initialization failed", suggestion: "Check task registration and scheduler configuration.", severity: ERROR_FATAL}
    if code == ERR_RTOS_TASK_FAILED:
        return {message: "SageRTOS task execution failed", suggestion: "The task function threw an error. Check task implementation.", severity: ERROR_CRITICAL}
    if code == ERR_RTOS_DEADLOCK:
        return {message: "SageRTOS deadlock detected", suggestion: "All tasks are blocked. Check task dependencies and yield points.", severity: ERROR_FATAL}
    if code == ERR_SRVM_LOAD_FAILED:
        return {message: "SRVM failed to load bytecode", suggestion: "Verify SRVM source files are staged: ./sagemake setup-srvm.", severity: ERROR_CRITICAL}
    if code == ERR_SRVM_RUNTIME_ERROR:
        return {message: "SRVM runtime error", suggestion: "Check SRVM VM execution context and bytecode validity.", severity: ERROR_CRITICAL}
    if code == ERR_DRIVER_LOAD_FAILED:
        return {message: "Driver failed to load", suggestion: "Check driver source compilation and MMIO address configuration.", severity: ERROR_WARNING}
    if code == ERR_DRIVER_MMIO_FAULT:
        return {message: "Driver MMIO access fault", suggestion: "Verify the MMIO base address for this driver is correct.", severity: ERROR_CRITICAL}

    ## Unknown error
    return {message: "Unknown error", suggestion: "No additional information available.", severity: ERROR_FATAL}

## --- Error Counter / Log ---

let error_count = 0
let error_last_code = 0
let error_last_message = ""

proc error_record(code, msg):
    error_count = error_count + 1
    error_last_code = code
    error_last_message = msg

## --- Public API ---

proc error_raise(code):
    let info = get_error_info(code)
    error_record(code, info.message)
    print("\n")
    print("========================================\n")
    if info.severity == ERROR_FATAL:
        print("  *** KERNEL PANIC (FATAL) ***\n")
    elif info.severity == ERROR_CRITICAL:
        print("  *** CRITICAL ERROR ***\n")
    elif info.severity == ERROR_WARNING:
        print("  *** WARNING ***\n")
    else:
        print("  *** NOTICE ***\n")

    print("========================================\n")
    print("\n")
    print("  Error Code:    0x")
    print(code)
    print("\n")
    print("  Subsystem:     ")
    print(error_subsystem_name(code))
    print("\n")
    print("  Severity:      ")
    print(error_severity_name(info.severity))
    print("\n")
    print("  Message:       ")
    print(info.message)
    print("\n")
    print("\n")
    print("  Suggestion:    ")
    print(info.suggestion)
    print("\n")
    print("\n")
    print("  Error Count:   ")
    print(error_count)
    print("\n")
    print("\n")
    print("  System State:\n")
    print("    Architecture: RISC-V 64 (rv64imac)\n")
    print("    VM:           MetalRV64 (Q32.32 fixed-point)\n")
    print("    Board:        QEMU virt\n")
    print("    Kernel:       SageOS-RV v0.2.0\n")
    print("\n")
    print("========================================\n")
    print("\n")

    if info.severity == ERROR_FATAL:
        print("  The system has encountered an unrecoverable error.\n")
        print("  Please review the information above and report this\n")
        print("  issue at: github.com/Night-Traders-Dev/SageOS-RV/issues\n")
        print("\n")
        print("  System halted.\n")
        print("========================================\n")
        ## On real hardware, this would trigger a machine reset.
        ## In the VM, we halt.

proc error_severity_name(sev):
    if sev == ERROR_FATAL:
        return "FATAL"
    if sev == ERROR_CRITICAL:
        return "CRITICAL"
    if sev == ERROR_WARNING:
        return "WARNING"
    if sev == ERROR_INFO:
        return "INFO"
    return "UNKNOWN"

proc error_subsystem_name(code):
    let subsys = code & 0xF000
    if subsys == SUBSYS_KERNEL:
        return "KERNEL"
    if subsys == SUBSYS_VM:
        return "VM"
    if subsys == SUBSYS_MEMORY:
        return "MEMORY"
    if subsys == SUBSYS_UART:
        return "UART"
    if subsys == SUBSYS_TIMER:
        return "TIMER"
    if subsys == SUBSYS_DTB:
        return "DTB"
    if subsys == SUBSYS_VMM:
        return "VMM"
    if subsys == SUBSYS_SHELL:
        return "SHELL"
    if subsys == SUBSYS_RTOS:
        return "RTOS"
    if subsys == SUBSYS_SRVM:
        return "SRVM"
    if subsys == SUBSYS_DRIVER:
        return "DRIVER"
    return "UNKNOWN"
