## kernel/kmain.sage — SageOS-RV Kernel Entry Point
##
## Called from boot.S after stack setup and BSS zeroing.
## This is the first Sage code to execute in S-mode.
##
## Kernel initialization sequence:
##   1. Console (UART)
##   2. Memory (PMM + VMM)
##   3. Interrupts (PLIC + trap vector)
##   4. Timer (CLINT / SBI timer)
##   5. Device tree parsing
##   6. SRVM (Sage RISC-V Virtual Machine)
##   7. Shell or init process

import srvm_core
import srvm_vm
from srvm_vm import SRVM

## --- Kernel Configuration ---

let KERNEL_VERSION = "0.1.0-alpha"
let KERNEL_NAME = "SageOS-RV"

## Memory layout (QEMU virt)
let MEM_BASE = 0x80200000
let MEM_SIZE = 128 * 1024 * 1024
let PAGE_SIZE = 4096

## UART
let UART_BASE = 0x10000000
let UART_THR = 0
let UART_RBR = 0
let UART_IER = 1
let UART_FCR = 2
let UART_LCR = 3
let UART_LSR = 5
let UART_LSR_THRE = 0x20
let UART_LSR_DR = 0x01

## --- Console ---

proc console_init():
    ## Initialize 16550A UART
    ## Disable interrupts
    mem_write(UART_BASE + UART_IER, 1, 0)
    ## Enable FIFO, clear them, with 14-byte threshold
    mem_write(UART_BASE + UART_FCR, 1, 0xC7)
    ## Set 8N1, no parity, one stop bit
    mem_write(UART_BASE + UART_LCR, 1, 0x03)
    ## Enable THRE mode (we'll poll LSR for TX ready)
    pass

proc uart_putc(ch):
    ## Wait for transmit holding register empty
    while (mem_read(UART_BASE + UART_LSR, 1) & UART_LSR_THRE) == 0:
        pass
    mem_write(UART_BASE + UART_THR, 1, ch)

proc uart_getc():
    ## Check if data available
    if (mem_read(UART_BASE + UART_LSR, 1) & UART_LSR_DR) == 0:
        return -1
    return mem_read(UART_BASE + UART_RBR, 1)

proc console_puts(s):
    let i = 0
    while i < len(s):
        uart_putc(char_to_int(s, i))
        i = i + 1

proc char_to_int(s, idx):
    let ch = s[idx]
    if ch == "0": return 48
    if ch == "1": return 49
    if ch == "2": return 50
    if ch == "3": return 51
    if ch == "4": return 52
    if ch == "5": return 53
    if ch == "6": return 54
    if ch == "7": return 55
    if ch == "8": return 56
    if ch == "9": return 57
    if ch == "a": return 97
    if ch == "b": return 98
    if ch == "c": return 99
    if ch == "d": return 100
    if ch == "e": return 101
    if ch == "f": return 102
    if ch == "g": return 103
    if ch == "h": return 104
    if ch == "i": return 105
    if ch == "j": return 106
    if ch == "k": return 107
    if ch == "l": return 108
    if ch == "m": return 109
    if ch == "n": return 110
    if ch == "o": return 111
    if ch == "p": return 112
    if ch == "q": return 113
    if ch == "r": return 114
    if ch == "s": return 115
    if ch == "t": return 116
    if ch == "u": return 117
    if ch == "v": return 118
    if ch == "w": return 119
    if ch == "x": return 120
    if ch == "y": return 121
    if ch == "z": return 122
    if ch == "A": return 65
    if ch == "B": return 66
    if ch == "C": return 67
    if ch == "D": return 68
    if ch == "E": return 69
    if ch == "F": return 70
    if ch == "G": return 71
    if ch == "H": return 72
    if ch == "I": return 73
    if ch == "J": return 74
    if ch == "K": return 75
    if ch == "L": return 76
    if ch == "M": return 77
    if ch == "N": return 78
    if ch == "O": return 79
    if ch == "P": return 80
    if ch == "Q": return 81
    if ch == "R": return 82
    if ch == "S": return 83
    if ch == "T": return 84
    if ch == "U": return 85
    if ch == "V": return 86
    if ch == "W": return 87
    if ch == "X": return 88
    if ch == "Y": return 89
    if ch == "Z": return 90
    if ch == " ": return 32
    if ch == "\n": return 10
    if ch == "\r": return 13
    if ch == "\t": return 9
    if ch == "!": return 33
    if ch == "\"": return 34
    if ch == "#": return 35
    if ch == "$": return 36
    if ch == "%": return 37
    if ch == "&": return 38
    if ch == "'": return 39
    if ch == "(": return 40
    if ch == ")": return 41
    if ch == "*": return 42
    if ch == "+": return 43
    if ch == ",": return 44
    if ch == "-": return 45
    if ch == ".": return 46
    if ch == "/": return 47
    if ch == ":": return 58
    if ch == ";": return 59
    if ch == "<": return 60
    if ch == "=": return 61
    if ch == ">": return 62
    if ch == "?": return 63
    if ch == "@": return 64
    if ch == "[": return 91
    if ch == "]": return 93
    if ch == "^": return 94
    if ch == "_": return 95
    if ch == "{": return 123
    if ch == "|": return 124
    if ch == "}": return 125
    if ch == "~": return 126
    return 63

proc console_put_hex(val):
    let hex = "0123456789ABCDEF"
    console_puts("0x")
    let started = false
    let i = 60
    while i >= 0:
        let nibble = (val >> i) & 0xF
        if nibble != 0 or started or i == 0:
            uart_putc(char_to_int(hex, nibble))
            started = true
        i = i - 4

proc console_put_dec(val):
    if val == 0:
        uart_putc(48)
        return
    let buf = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    let pos = 19
    let n = val
    while n > 0:
        buf[pos] = n % 10
        n = n / 10
        pos = pos - 1
    let i = pos + 1
    while i < 20:
        uart_putc(buf[i] + 48)
        i = i + 1

## --- Panic ---

proc panic(msg):
    console_puts("\n\nKERNEL PANIC: ")
    console_puts(msg)
    console_puts("\n\n")
    console_puts("System halted.\n")
    ## Infinite loop
    while true:
        pass

## --- Memory Manager (Stubs for Phase 3) ---

let pmm_bitmap = {}
let pmm_total_pages = 0
let pmm_free_pages = 0

proc pmm_init(base, size):
    let pages = size / PAGE_SIZE
    pmm_total_pages = pages
    pmm_free_pages = pages
    console_puts("  PMM: ")
    console_put_dec(pages)
    console_puts(" pages (")
    console_put_dec(size / 1024)
    console_puts(" KB)\n")

proc pmm_alloc_page():
    if pmm_free_pages == 0:
        return 0
    pmm_free_pages = pmm_free_pages - 1
    return MEM_BASE + (pmm_total_pages - pmm_free_pages) * PAGE_SIZE

proc pmm_free_page(addr):
    pmm_free_pages = pmm_free_pages + 1

## --- Interrupt Setup (Stub) ---

let PLIC_BASE = 0x0C000000
let CLINT_BASE = 0x02000000

proc interrupt_init():
    console_puts("  Interrupts: PLIC + trap vector setup\n")
    ## Set up trap vector (stvec)
    ## In real implementation: write to stvec CSR
    pass

proc timer_init():
    console_puts("  Timer: SBI set_timer\n")
    pass

## --- Device Tree (Stub) ---

proc dtb_init(dtb_addr):
    console_puts("  DTB: parsing at ")
    console_put_hex(dtb_addr)
    console_puts("\n")

## --- SRVM (Sage RISC-V Virtual Machine) ---
## Global VM instance — initialized once, shared across shell commands.
## SRVM is pure Sage: no libc, no malloc, no host OS dependencies.
## It interprets SageVM RV64I bytecode stored in the constants pool.

var srvm_instance = nil

proc srvm_init():
    console_puts("[SRVM] Initializing Sage RISC-V VM...\n")
    srvm_instance = SRVM()
    srvm_instance.state.safe_mode = true   ## Enforce call/array/try depth limits
    console_puts("[SRVM] Ready (safe_mode=true, max_call_depth=")
    console_put_dec(srvm_instance.state.max_call_depth)
    console_puts(")\n")

## Run a bytecode payload through SRVM.
## bytecode is a list of byte-sized integers (little-endian 32-bit words).
proc srvm_exec(bytecode):
    if srvm_instance == nil:
        console_puts("[SRVM] Not initialized\n")
        return
    srvm_instance.run(bytecode)

## Demo payload: encode a single HALT instruction (OP_VMSYS, f3=F3_VM_OPS, rs1=VMO_HALT)
## Encoding: opcode=0x73, rd=0, funct3=0x000, rs1=VMO_HALT(0x01), rs2=0, funct7=0
## raw = 0x73 | (0x01 << 15) = 0x00008073
proc srvm_run_demo():
    console_puts("[SRVM] Running demo (HALT instruction)...\n")
    ## 0x00008073 in little-endian bytes: 0x73, 0x80, 0x00, 0x00
    let demo_bytecode = [0x73, 0x80, 0x00, 0x00]
    srvm_exec(demo_bytecode)
    console_puts("[SRVM] Demo complete\n")

## --- Kernel Banner ---

proc print_banner():
    console_puts("\n")
    console_puts("========================================\n")
    console_puts("  ")
    console_puts(KERNEL_NAME)
    console_puts(" v")
    console_puts(KERNEL_VERSION)
    console_puts("\n")
    console_puts("  Pure Sage Operating System\n")
    console_puts("  RISC-V 64 | QEMU virt\n")
    console_puts("========================================\n")
    console_puts("\n")

## --- Shell ---

let shell_running = true

proc shell_help():
    console_puts("SageOS-RV Shell Commands:\n")
    console_puts("  help       Show this help\n")
    console_puts("  version    Show kernel version\n")
    console_puts("  mem        Show memory statistics\n")
    console_puts("  srvm       Show SRVM status and run demo\n")
    console_puts("  about      About SageOS\n")
    console_puts("  halt       Halt the CPU\n")
    console_puts("  echo <text> Print text\n\n")

proc shell_version():
    console_puts("SageOS-RV v")
    console_puts(KERNEL_VERSION)
    console_puts("\nKernel: ")
    console_puts(KERNEL_NAME)
    console_puts("\nArch: RISC-V 64 (rv64imac)\n")
    console_puts("VM: SRVM (Sage RISC-V VM, pure Sage)\n\n")

proc shell_mem():
    console_puts("Memory Statistics:\n")
    console_puts("  Total pages: ")
    console_put_dec(pmm_total_pages)
    console_puts("\n  Free pages:  ")
    console_put_dec(pmm_free_pages)
    console_puts("\n  Used pages:  ")
    console_put_dec(pmm_total_pages - pmm_free_pages)
    console_puts("\n\n")

proc shell_srvm():
    console_puts("SRVM Status:\n")
    if srvm_instance == nil:
        console_puts("  State: not initialized\n\n")
        return
    console_puts("  State: ready\n")
    console_puts("  safe_mode: ")
    if srvm_instance.state.safe_mode:
        console_puts("true\n")
    else:
        console_puts("false\n")
    console_puts("  max_call_depth: ")
    console_put_dec(srvm_instance.state.max_call_depth)
    console_puts("\n")
    console_puts("  Running demo bytecode...\n")
    srvm_run_demo()
    console_puts("\n")

proc shell_about():
    console_puts("SageOS-RV -- A Pure Sage Operating System\n")
    console_puts("Target: LicheeRV Nano (Sophgo SG2002, RISC-V 64)\n")
    console_puts("Philosophy: C only where silicon requires it.\n")
    console_puts("            Everything else is Pure Sage.\n\n")
    console_puts("VM: SRVM from SageVM (github.com/Night-Traders-Dev/SageVM)\n")
    console_puts("    RV64I bytecode interpreter, pure Sage, no libc.\n\n")

proc shell_process(line):
    if line == "help":
        shell_help()
    elif line == "version":
        shell_version()
    elif line == "mem":
        shell_mem()
    elif line == "srvm":
        shell_srvm()
    elif line == "about":
        shell_about()
    elif line == "halt":
        console_puts("System halting...\n")
        shell_running = false
    else:
        ## echo prefix
        if len(line) > 5:
            let prefix = line[0] + line[1] + line[2] + line[3]
            if prefix == "echo":
                let i = 5
                while i < len(line):
                    uart_putc(char_to_int(line, i))
                    i = i + 1
                uart_putc(10)
                return
        if len(line) > 0:
            console_puts("Unknown command. Type 'help' for available commands.\n")

proc shell_main():
    console_puts("SageOS-RV Shell (type 'help' for commands)\n\n")
    let buf = ""
    while shell_running:
        console_puts("sage# ")
        buf = ""
        let c = uart_getc()
        while c != 10 and c != 13:
            if c >= 32 and c < 127:
                uart_putc(c)
                buf = buf + chr(c)
            c = uart_getc()
        uart_putc(10)
        shell_process(buf)

## --- Kernel Main ---
## This is the C-callable entry point from boot.S
## It receives hart_id in a0 and dtb_addr in a1

proc sage_kernel_main():
    ## Phase 1: Console
    console_init()
    print_banner()

    console_puts("[1/7] Console initialized\n")

    ## Phase 2: Memory
    console_puts("[2/7] Initializing memory...\n")
    pmm_init(MEM_BASE, MEM_SIZE)

    ## Phase 3: Interrupts
    console_puts("[3/7] Initializing interrupts...\n")
    interrupt_init()

    ## Phase 4: Timer
    console_puts("[4/7] Initializing timer...\n")
    timer_init()

    ## Phase 5: Device Tree
    console_puts("[5/7] Parsing device tree...\n")
    dtb_init(0)

    ## Phase 6: SRVM
    console_puts("[6/7] Initializing SRVM...\n")
    srvm_init()

    ## Phase 7: Shell
    console_puts("[7/7] Starting shell...\n\n")

    ## Drop to shell
    shell_main()

    ## Should never return
    panic("kernel returned from shell")
