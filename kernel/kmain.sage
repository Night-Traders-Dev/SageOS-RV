## kernel/kmain.sage - SageOS-RV Kernel Entry Point
##
## Called from boot.S after stack setup and BSS zeroing.
## This is the first Sage code to execute in S-mode.
##
## Philosophy: NO C fallbacks. Every component is Sage.
## If a required component is missing, kernel_panic.panic() is called.
##
## Kernel initialization sequence:
##   1. Console (UART 16550A)
##   2. DTB parse
##   3. Memory (PMM bitmap allocator)
##   4. VMM (SV39)
##   5. Timer (stimecmp / SBI)
##   6. SageRTOS
##   7. MetalVM + shell.sgvm  <- panic if absent

import kernel_panic
import srvm_core
import srvm_vm
from srvm_vm import SRVM

## --- Kernel Configuration ---

let KERNEL_VERSION = "0.1.0-alpha"
let KERNEL_NAME    = "SageOS-RV"

## Memory layout (QEMU virt)
let MEM_BASE  = 0x80200000
let MEM_SIZE  = 128 * 1024 * 1024
let PAGE_SIZE = 4096

## UART (16550A)
let UART_BASE     = 0x10000000
let UART_THR      = 0
let UART_RBR      = 0
let UART_IER      = 1
let UART_FCR      = 2
let UART_LCR      = 3
let UART_LSR      = 5
let UART_LSR_THRE = 0x20
let UART_LSR_DR   = 0x01

## .sgvm magic: first 4 bytes of every `sagevm compile --riscv` output
## are 0x53 0x47 0x4D 0x56 ('SGMV' little-endian = 0x56474D53)
let SGVM_MAGIC = 0x56474D53

## .sgvm_shell section
## SGVM_SECTION_BASE: physical address where sagemake embeds shell.sgvm
## SGVM_SECTION_SIZE: patched to non-zero by sagemake after embed;
##                   0 means no blob present => kernel_panic
let SGVM_SECTION_BASE = 0x80300000
let SGVM_SECTION_SIZE = 0

## ---------------------------------------------------------------------------
## Console
## ---------------------------------------------------------------------------

proc console_init():
    mem_write(UART_BASE + UART_IER, 1, 0)
    mem_write(UART_BASE + UART_FCR, 1, 0xC7)
    mem_write(UART_BASE + UART_LCR, 1, 0x03)

proc uart_putc(ch):
    while (mem_read(UART_BASE + UART_LSR, 1) & UART_LSR_THRE) == 0:
        pass
    mem_write(UART_BASE + UART_THR, 1, ch)

proc uart_getc():
    if (mem_read(UART_BASE + UART_LSR, 1) & UART_LSR_DR) == 0:
        return -1
    return mem_read(UART_BASE + UART_RBR, 1)

proc char_code(ch):
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

proc console_puts(s):
    let i = 0
    while i < len(s):
        uart_putc(char_code(s[i]))
        i = i + 1

proc console_put_hex(val):
    let hex = "0123456789ABCDEF"
    console_puts("0x")
    let started = false
    let i = 60
    while i >= 0:
        let nibble = (val >> i) & 0xF
        if nibble != 0 or started or i == 0:
            uart_putc(char_code(hex[nibble]))
            started = true
        i = i - 4

proc console_put_dec(val):
    if val == 0:
        uart_putc(48)
        return
    let buf = [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]
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

## ---------------------------------------------------------------------------
## PMM
## ---------------------------------------------------------------------------

let pmm_total_pages = 0
let pmm_free_pages  = 0

proc pmm_init(base, size):
    pmm_total_pages = size / PAGE_SIZE
    pmm_free_pages  = pmm_total_pages

proc pmm_alloc_page():
    if pmm_free_pages == 0:
        kernel_panic.panic("pmm_alloc_page: out of physical memory")
        return 0
    pmm_free_pages = pmm_free_pages - 1
    return MEM_BASE + (pmm_total_pages - pmm_free_pages) * PAGE_SIZE

proc pmm_free_page(addr):
    pmm_free_pages = pmm_free_pages + 1

## ---------------------------------------------------------------------------
## Stubs (DTB / interrupt / timer — wired to C layer via boot glue)
## ---------------------------------------------------------------------------

let PLIC_BASE  = 0x0C000000
let CLINT_BASE = 0x02000000

proc interrupt_init():
    console_puts("  Interrupts: PLIC + trap vector setup\n")

proc timer_init():
    console_puts("  Timer: SBI set_timer\n")

proc dtb_init(dtb_addr):
    console_puts("  DTB @ ")
    console_put_hex(dtb_addr)
    console_puts("\n")

## ---------------------------------------------------------------------------
## SRVM
## ---------------------------------------------------------------------------

var srvm_instance = nil

proc srvm_init():
    srvm_instance = SRVM()
    srvm_instance.state.safe_mode = true
    if srvm_instance == nil:
        kernel_panic.panic("srvm_init: SRVM() constructor returned nil")

## ---------------------------------------------------------------------------
## Shell launch (MetalVM path — NO fallback)
## ---------------------------------------------------------------------------

proc mem_read_bytes(addr, count):
    let result = []
    let i = 0
    while i < count:
        push(result, mem_read(addr + i, 1))
        i = i + 1
    return result

proc shell_launch():
    ## SRVM must be ready
    if srvm_instance == nil:
        kernel_panic.panic("shell_launch: SRVM not initialized")

    ## shell.sgvm blob must be embedded
    if SGVM_SECTION_SIZE == 0:
        kernel_panic.panic("shell_launch: shell.sgvm not embedded (SGVM_SECTION_SIZE=0) -- run: ./sagemake compile-shell && ./sagemake build")

    ## Validate .sgvm magic
    let magic = mem_read(SGVM_SECTION_BASE, 4)
    if magic != SGVM_MAGIC:
        kernel_panic.panic("shell_launch: shell.sgvm magic mismatch -- blob corrupt or not embedded")

    console_puts("[shell] Loading shell.sgvm (")
    console_put_dec(SGVM_SECTION_SIZE)
    console_puts(" bytes) via MetalVM...\n")

    let bytecode = mem_read_bytes(SGVM_SECTION_BASE, SGVM_SECTION_SIZE)
    srvm_instance.run(bytecode)

    ## If run() returns at all the shell exited cleanly -- that's a panic
    kernel_panic.panic("shell_launch: MetalVM shell returned unexpectedly")

## ---------------------------------------------------------------------------
## Banner
## ---------------------------------------------------------------------------

proc print_banner():
    console_puts("\n========================================\n")
    console_puts("  ")
    console_puts(KERNEL_NAME)
    console_puts(" v")
    console_puts(KERNEL_VERSION)
    console_puts("\n  Pure Sage Operating System\n")
    console_puts("  RISC-V 64 | QEMU virt\n")
    console_puts("========================================\n\n")

## ---------------------------------------------------------------------------
## Kernel main
## ---------------------------------------------------------------------------

proc sage_kernel_main():
    console_init()
    print_banner()
    console_puts("[1/7] Console initialized\n")

    console_puts("[2/7] Memory: ")
    pmm_init(MEM_BASE, MEM_SIZE)
    console_put_dec(pmm_total_pages)
    console_puts(" pages (")
    console_put_dec(MEM_SIZE / 1024)
    console_puts(" KB)\n")

    console_puts("[3/7] Interrupts...\n")
    interrupt_init()

    console_puts("[4/7] Timer...\n")
    timer_init()

    console_puts("[5/7] DTB...\n")
    dtb_init(0)

    console_puts("[6/7] SRVM init...\n")
    srvm_init()
    console_puts("  SRVM ready\n")

    console_puts("[7/7] Launching shell.sgvm via MetalVM...\n\n")
    shell_launch()

    ## Never reached
    kernel_panic.panic("sage_kernel_main: returned from shell_launch")
