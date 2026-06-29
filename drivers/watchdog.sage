## drivers/watchdog.sage — Pure-Sage Watchdog Driver for SG2002
##
## DesignWare Watchdog Timer (DW_WDT) on Sophgo SG2002.
## Provides system watchdog with configurable timeout.
##
## Register map:
##   0x00 — WDT_CR       Control register
##   0x04 — WDT_TORR     Timeout range register
##   0x08 — WDT_CCVR     Current counter value
##   0x0C — WDT_CRR      Counter restart register
##   0x10 — WDT_STAT     Status register
##   0x14 — WDT_EOI      End of interrupt

let WDT_BASE = 0x03010000

## Register offsets
let WDT_CR    = 0x00
let WDT_TORR  = 0x04
let WDT_CCVR  = 0x08
let WDT_CRR   = 0x0C
let WDT_STAT  = 0x10
let WDT_EOI   = 0x14

## Control register bits
let WDT_CR_ENABLE   = (1 << 0)    ## Watchdog enable
let WDT_CR_RMOD     = (1 << 1)    ## Response mode (0=reset, 1=interrupt)
let WDT_CR_RPL_MASK = (3 << 2)    ## Reset pulse length

## Timeout ranges (TORR values)
## TORR = 0: 2^16 cycles
## TORR = 1: 2^17 cycles
## ...
## TORR = 15: 2^31 cycles
## For WDT clock = 100 MHz: TORR=7 -> 2^23 / 100M = 83ms

## Counter restart magic value
let WDT_CRR_MAGIC = 0x76

## --- Watchdog API ---

proc wdt_init(timeout_torr):
    ## Disable watchdog first
    mem_write(WDT_BASE + WDT_CR, 0, 4)
    
    ## Set timeout range
    mem_write(WDT_BASE + WDT_TORR, timeout_torr & 0xF, 4)
    
    ## Enable watchdog with reset mode
    let cr = WDT_CR_ENABLE | (0 << 2)
    mem_write(WDT_BASE + WDT_CR, cr, 4)

proc wdt_kick():
    ## Restart the watchdog counter (pet the dog)
    mem_write(WDT_BASE + WDT_CRR, WDT_CRR_MAGIC, 4)

proc wdt_disable():
    mem_write(WDT_BASE + WDT_CR, 0, 4)

proc wdt_get_count():
    return mem_read(WDT_BASE + WDT_CCVR, 4)

proc wdt_get_status():
    ## Returns 1 if watchdog fired (interrupt mode only)
    return mem_read(WDT_BASE + WDT_STAT, 4)

proc wdt_clear_interrupt():
    mem_write(WDT_BASE + WDT_EOI, 0, 4)

## --- Convenience presets ---

proc wdt_init_100ms():
    ## ~100ms timeout at 100 MHz WDT clock
    ## 2^23 / 100 MHz = 83 ms (TORR=7)
    ## 2^24 / 100 MHz = 167 ms (TORR=8)
    wdt_init(7)

proc wdt_init_1s():
    ## ~1 second timeout
    ## 2^27 / 100 MHz = 1.34s (TORR=11)
    wdt_init(10)

proc wdt_init_5s():
    ## ~5 second timeout
    ## 2^29 / 100 MHz = 5.36s (TORR=13)
    wdt_init(12)
