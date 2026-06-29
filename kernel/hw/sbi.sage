## kernel/hw/sbi.sage — Sage SBI (Supervisor Binary Interface) Module
##
## Ported from kernel/hw/sbi.h (116 lines of C inline asm).
## Provides Sage wrappers for SBI ecalls via VM builtins.
##
## SBI v3.0 Extension IDs:
##   TIME    0x54494D45 — Set timer (stimecmp)
##   SRST    0x53525354 — System reset (shutdown/reboot)
##   DBCN    0x4442434E — Debug console (read/write byte)
##   Legacy  0x01-0x08  — Console putchar/getchar, shutdown

## --- SBI Extension IDs ---

let SBI_TIME  = 0x54494D45
let SBI_SRST  = 0x53525354
let SBI_DBCN  = 0x4442434E

## --- SBI Function IDs ---

let SBI_TIME_SET_TIMER     = 0
let SBI_SRST_SYSTEM_RESET  = 0
let SBI_DBCN_WRITE_BYTE    = 2
let SBI_DBCN_READ          = 1

## --- SRST Reset Types ---

let SBI_RESET_SHUTDOWN     = 0
let SBI_RESET_COLD_REBOOT  = 1
let SBI_RESET_WARM_REBOOT  = 2

## --- Legacy Console Extension IDs ---

let SBI_LEGACY_PUTCHAR  = 0x01
let SBI_LEGACY_GETCHAR  = 0x02
let SBI_LEGACY_SHUTDOWN = 0x08

## --- SBI API ---
##
## Note: Actual ecall execution requires C/asm bridge.
## These are reference implementations documenting the calling convention.
## The VM provides equivalent builtins (uart_putc, uart_getchar, etc.)

proc sbi_set_timer(stime_value):
    ## Set mtimecmp to stime_value (triggers timer interrupt at that time)
    ## SBI convention: a7=EID, a6=FID, a0=stime_value
    pass   ## Requires ecall builtin

proc sbi_shutdown():
    ## System reset — shutdown
    pass

proc sbi_reboot():
    ## System reset — cold reboot
    pass

proc sbi_putchar(c):
    ## Output character to debug console
    pass

proc sbi_getchar():
    ## Read character from debug console (-1 if none)
    return -1

## --- SBI Extension Probe ---

proc sbi_probe_extension(eid):
    ## Probe whether an SBI extension is available
    ## Returns: 0 = not available, non-zero = version/available
    return 0

## --- Timer Abstraction (uses SBI TIME or SSTC) ---

proc sbi_timer_init():
    ## Initialize timer subsystem
    ## Detects SSTC (stimecmp CSR) vs SBI TIME extension
    pass
