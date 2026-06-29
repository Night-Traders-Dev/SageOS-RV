## drivers/timer.sage — Pure-Sage Timer Driver for SG2002 / RISC-V
##
## Uses the RISC-V machine timer (mtimecmp CSR) via SBI TIME extension.
## For SG2002, the ACLINT MTIMER provides the hardware timer.
##
## Timer registers (if accessing directly, not via SBI):
##   mtime     — 64-bit timer counter (read-only)
##   mtimecmp  — 64-bit timer compare (write to set next interrupt)

## --- Timer Constants ---
let TIMER_FREQ_QEMU   = 10000000   ## 10 MHz on QEMU virt
let TIMER_FREQ_SG2002 = 25000000   ## 25 MHz on SG2002

## --- Timer API (SBI-based) ---

proc timer_get_ticks():
    ## Read mtime CSR directly
    ## On RV64, mtime is accessed via the 'time' CSR (rdtime pseudo-instruction)
    ## In Sage, use SBI TIME extension or direct CSR read
    ## For bare-metal, we use the built-in SRVM opcode.
    return 0   ## Placeholder — requires builtin support

proc timer_set_cmp(ticks):
    ## Set mtimecmp via SBI TIME extension
    ## SBI set_timer(stime_value)
    return 0   ## Placeholder — requires SBI ecall builtin

## --- Periodic Timer ---

let timer_ticks = 0
let timer_interval = 0

proc timer_init(freq_hz, interval_ms):
    timer_interval = (freq_hz / 1000) * interval_ms
    timer_ticks = 0

proc timer_poll(freq_hz):
    ## Poll timer and fire callback if interval elapsed
    ## Returns 1 if timer tick occurred
    let current = timer_get_ticks()
    if current >= timer_next:
        timer_next = current + timer_interval
        timer_ticks = timer_ticks + 1
        return 1
    return 0

let timer_next = 0

proc timer_read():
    return timer_ticks

## --- Delay functions (busy-wait) ---

proc delay_us(microseconds):
    ## Busy-wait delay for N microseconds
    ## Assumes ~1 GHz CPU (C906), ~1 cycle per loop iteration
    ## For accurate delays, use the timer hardware
    let count = microseconds * 1000
    while count > 0:
        count = count - 1

proc delay_ms(milliseconds):
    delay_us(milliseconds * 1000)
