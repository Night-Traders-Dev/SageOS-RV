## drivers/syscon.sage — Pure-Sage System Controller Driver for SG2002
##
## Provides system-level control functions:
##   - Soft reset / power-off
##   - Clock configuration
##   - Boot mode selection
##
## Register map (SG2002 system controller at 0x03001000):
##   0x000 — CHIP_ID        Chip identification
##   0x004 — CHIP_REV       Chip revision
##   0x008 — SYS_CTRL       System control
##   0x02C — SOFT_RST       Software reset
##   0x030 — BOOT_SEL       Boot select
##   0x1C0 — PLL_CTRL       PLL control
##   0x1E0 — CLK_DIV0       Clock divider 0
##   0x1E4 — CLK_DIV1       Clock divider 1

let SYSCON_BASE = 0x03001000

## Register offsets
let SYSCON_CHIP_ID   = 0x000
let SYSCON_CHIP_REV  = 0x004
let SYSCON_SYS_CTRL  = 0x008
let SYSCON_SOFT_RST  = 0x02C
let SYSCON_BOOT_SEL  = 0x030
let SYSCON_PLL_CTRL  = 0x1C0
let SYSCON_CLK_DIV0  = 0x1E0
let SYSCON_CLK_DIV1  = 0x1E4

## System control bits
let SYS_CTRL_WARM_RST  = (1 << 0)   ## Write 1 to trigger warm reset
let SYS_CTRL_SHUTDOWN  = (1 << 1)   ## Write 1 to power off

## --- SysCon API ---

proc syscon_read_chip_id():
    return mem_read(SYSCON_BASE + SYSCON_CHIP_ID, 4)

proc syscon_read_chip_rev():
    return mem_read(SYSCON_BASE + SYSCON_CHIP_REV, 4)

proc syscon_reset():
    ## Trigger a warm system reset
    let ctrl = mem_read(SYSCON_BASE + SYSCON_SYS_CTRL, 4)
    mem_write(SYSCON_BASE + SYSCON_SYS_CTRL, ctrl | SYS_CTRL_WARM_RST, 4)
    ## Should not reach here
    while true:
        pass

proc syscon_shutdown():
    ## Power off the system
    let ctrl = mem_read(SYSCON_BASE + SYSCON_SYS_CTRL, 4)
    mem_write(SYSCON_BASE + SYSCON_SYS_CTRL, ctrl | SYS_CTRL_SHUTDOWN, 4)
    while true:
        pass

proc syscon_get_boot_mode():
    return mem_read(SYSCON_BASE + SYSCON_BOOT_SEL, 4)

## --- Chip identification ---

proc syscon_print_info():
    print("SoC Info:\n")
    print("  Chip ID:  0x")
    print(syscon_read_chip_id())
    print("\n")
    print("  Revision: 0x")
    print(syscon_read_chip_rev())
    print("\n")
    print("  Boot mode: 0x")
    print(syscon_get_boot_mode())
    print("\n")

let SG2002_CHIP_ID = 0x53473230   ## "SG20" in ASCII hex
let CV181X_CHIP_ID = 0x43383138   ## "C818" in ASCII hex
