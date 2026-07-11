## boot/start.sage — SageBoot entry point for RISC-V 64
##
## This module generates the boot sequence for SageOS-RV.
## It is transpiled to C by the Sage compiler, then compiled
## with the RISC-V cross-compiler and linked with boot.S.
##
## Architecture: RISC-V 64 (rv64imac, lp64 ABI)
## Target: QEMU virt / LicheeRV Nano (SG2002)
## Entry: S-mode via OpenSBI

## --- SBI Interface ---
## RISC-V Supervisor Binary Interface calls
## Used for console output, timer, and system reset

## SBI ecall convention:
##   a7 = EID (extension ID)
##   a6 = FID (function ID)
##   a0 = return value

let SBI_SET_TIMER = 0x00
let SBI_CONSOLE_PUTCHAR = 0x01
let SBI_CONSOLE_GETCHAR = 0x02
let SBI_CLEAR_IPI = 0x03
let SBI_SEND_IPI = 0x04
let SBI_REMOTE_FENCE_I = 0x05
let SBI_REMOTE_SFENCE_VMA = 0x06
let SBI_REMOTE_HFENCE_GVMA = 0x07
let SBI_SYSTEM_RESET = 0x08

let SBI_EXT_SRST = 0x53525354
let SBI_EXT_DBCN = 0x4442434E

## --- UART Configuration ---
## QEMU virt:     16550A UART at 0x10000000
## LicheeRV Nano: 16550A UART at 0x04140000
## boot.S gets UART_BASE at compile time; boot.sage probes DTB to find it.

let UART_THR = 0
let UART_RBR = 0
let UART_LSR = 5
let UART_LSR_THRE = 0x20
let UART_LSR_DR = 0x01

## Probe UART base from DTB, fall back to compile-time default
let _uart_base = 0x10000000

## --- Boot Handoff Structure ---
## Passed to the kernel from the bootloader
## Values are filled from DTB at runtime where possible

proc create_handoff(hart_id, dtb_addr):
    let handoff = {}
    handoff["magic"] = 0x53414745
    handoff["version"] = 1
    handoff["hart_id"] = hart_id
    handoff["dtb_addr"] = dtb_addr
    ## Parse DTB to get actual memory/UART layout
    let dtb_info = dtb_parse(dtb_addr)
    if dtb_info.valid:
        handoff["mem_base"] = dtb_info.mem_base
        handoff["mem_size"] = dtb_info.mem_size
        handoff["uart_base"] = dtb_info.uart_base
        _uart_base = dtb_info.uart_base
    else:
        ## Fallback defaults (board-agnostic)
        handoff["mem_base"] = 0x80200000
        handoff["mem_size"] = 128 * 1024 * 1024
        handoff["uart_base"] = _uart_base
    return handoff

## --- Console Output ---
## Uses DTB-probed UART MMIO for early output

proc sbi_putchar(ch):
    let uart = _uart_base
    ## Wait for THR empty
    while (mem_read(uart + UART_LSR, 1) & UART_LSR_THRE) == 0:
        pass
    mem_write(uart + UART_THR, 1, ch)

proc sbi_puts(s):
    let i = 0
    while i < len(s):
        sbi_putchar(char_code(s, i))
        i = i + 1

proc sbi_put_hex(val):
    let hex = "0123456789ABCDEF"
    sbi_puts("0x")
    let i = 60
    while i >= 0:
        let nibble = (val >> i) & 0xF
        sbi_putchar(char_code(hex, nibble))
        i = i - 4

proc char_code(s, idx):
    ## Extract character code from string
    ## In Sage, string indexing returns the character
    let ch = s[idx]
    ## Map common characters to ASCII
    if ch >= "0" and ch <= "9":
        return ch[0] + 48
    if ch >= "A" and ch <= "Z":
        return ch[0] + 65
    if ch >= "a" and ch <= "z":
        return ch[0] + 97
    if ch == " ":
        return 32
    if ch == "\n":
        return 10
    if ch == "\r":
        return 13
    if ch == "\t":
        return 9
    return 63

## --- Boot Main ---
## Called from boot.S after stack setup and BSS zeroing

proc boot_main(hart_id, dtb_addr):
    ## Early console init
    sbi_puts("SageBoot: Starting...\n")
    sbi_puts("SageBoot: Hart ID = ")
    sbi_put_hex(hart_id)
    sbi_puts("\n")
    sbi_puts("SageBoot: DTB at ")
    sbi_put_hex(dtb_addr)
    sbi_puts("\n")

    ## Create handoff structure
    let handoff = create_handoff(hart_id, dtb_addr)

    sbi_puts("SageBoot: Handoff created\n")
    sbi_puts("SageBoot: Jumping to kernel\n\n")

    ## Return handoff to kernel
    return handoff
