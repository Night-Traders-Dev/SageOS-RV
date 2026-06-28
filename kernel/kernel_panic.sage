## kernel/kernel_panic.sage - SageOS-RV Kernel Panic Handler
##
## This module is the single point of no-return for fatal kernel errors.
## There are NO fallbacks. If this is reached, the system halts visibly.
##
## Usage:
##   import kernel_panic
##   kernel_panic.panic("reason string")
##
## On panic:
##   1. Print double-border banner to UART
##   2. Print reason string
##   3. Print register dump stubs (satp, sstatus, sepc, stval)
##   4. Infinite WFI loop — never returns

## UART base (QEMU virt / LicheeRV Nano)
let PANIC_UART_BASE  = 0x10000000
let PANIC_UART_THR   = 0
let PANIC_UART_LSR   = 5
let PANIC_UART_THRE  = 0x20

proc _panic_putc(ch):
    while (mem_read(PANIC_UART_BASE + PANIC_UART_LSR, 1) & PANIC_UART_THRE) == 0:
        pass
    mem_write(PANIC_UART_BASE + PANIC_UART_THR, 1, ch)

proc _panic_puts(s):
    let i = 0
    while i < len(s):
        let ch = s[i]
        ## inline ord() for bare-metal (no stdlib)
        _panic_putc(char_code(ch))
        i = i + 1

proc _panic_put_hex(val):
    _panic_puts("0x")
    let digits = "0123456789ABCDEF"
    let started = false
    let shift = 60
    while shift >= 0:
        let nibble = (val >> shift) & 0xF
        if nibble != 0 or started or shift == 0:
            _panic_putc(char_code(digits[nibble]))
            started = true
        shift = shift - 4

proc _panic_csr_read_satp():
    ## Returns satp CSR value via inline asm intrinsic.
    ## SageVM maps csr_read("satp") -> csrr rd, satp
    return csr_read("satp")

proc _panic_csr_read_sepc():
    return csr_read("sepc")

proc _panic_csr_read_sstatus():
    return csr_read("sstatus")

proc _panic_csr_read_stval():
    return csr_read("stval")

## ---------------------------------------------------------------------------
## panic(msg) -- the only public symbol in this module
## ---------------------------------------------------------------------------
proc panic(msg):
    _panic_puts("\n\n")
    _panic_puts("################################################################\n")
    _panic_puts("##                    KERNEL PANIC                           ##\n")
    _panic_puts("################################################################\n")
    _panic_puts("## Reason : ")
    _panic_puts(msg)
    _panic_puts("\n")
    _panic_puts("## satp   : ")
    _panic_put_hex(_panic_csr_read_satp())
    _panic_puts("\n")
    _panic_puts("## sepc   : ")
    _panic_put_hex(_panic_csr_read_sepc())
    _panic_puts("\n")
    _panic_puts("## sstatus: ")
    _panic_put_hex(_panic_csr_read_sstatus())
    _panic_puts("\n")
    _panic_puts("## stval  : ")
    _panic_put_hex(_panic_csr_read_stval())
    _panic_puts("\n")
    _panic_puts("################################################################\n")
    _panic_puts("## System halted. Reset to recover.                          ##\n")
    _panic_puts("################################################################\n")
    while true:
        pass
