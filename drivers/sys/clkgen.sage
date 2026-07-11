## drivers/sys/clkgen.sage — SG2002 Clock Generator Driver
##
## Manages clock tree for SG2002 SoC.
## CLKGEN block at 0x03002000, PLL control at 0x03001C00.
## Called during early board init to set up CPU and peripheral clocks.

let CLKGEN_BASE  = 0x03002000
let PLL_BASE     = 0x03001C00

## CLKGEN register offsets
let CLKGEN_CPU_CLK_DIV  = 0x00
let CLKGEN_AXI_CLK_DIV  = 0x04
let CLKGEN_AHB_CLK_DIV  = 0x08
let CLKGEN_APB_CLK_DIV  = 0x0C
let CLKGEN_UART_CLK_DIV = 0x10
let CLKGEN_SD_CLK_DIV   = 0x14
let CLKGEN_ENABLE       = 0x40

## PLL register offsets
let PLL_CPU_CTRL  = 0x00
let PLL_DDR_CTRL  = 0x04
let PLL_AXI_CTRL  = 0x08
let PLL_AUDIO_CTRL = 0x0C

proc clkgen_read32(offset):
    return mem_read(CLKGEN_BASE + offset, 4)

proc clkgen_write32(offset, val):
    mem_write(CLKGEN_BASE + offset, val, 4)

proc pll_read32(offset):
    return mem_read(PLL_BASE + offset, 4)

proc pll_write32(offset, val):
    mem_write(PLL_BASE + offset, val, 4)

proc clkgen_init():
    print("[CLK] Initializing SG2002 clock tree...\n")

    let clk_en = clkgen_read32(CLKGEN_ENABLE)
    if clk_en == 0xFFFFFFFF or clk_en == 0:
        clkgen_write32(CLKGEN_ENABLE, 0x01)
        print("[CLK] Clock generator enabled\n")
    else:
        print("[CLK] Clock generator already active (0x")
        print(clk_en)
        print(")\n")

    let cpu_div = clkgen_read32(CLKGEN_CPU_CLK_DIV)
    print("[CLK] CPU clock divider: 0x")
    print(cpu_div)
    print("\n")

    let uart_div = clkgen_read32(CLKGEN_UART_CLK_DIV)
    print("[CLK] UART clock divider: 0x")
    print(uart_div)
    print("\n")

    let sd_div = clkgen_read32(CLKGEN_SD_CLK_DIV)
    print("[CLK] SD clock divider: 0x")
    print(sd_div)
    print("\n")

    print("[CLK] Clock tree initialized.\n")
    return true

proc clkgen_set_uart_div(div):
    clkgen_write32(CLKGEN_UART_CLK_DIV, div & 0xFF)
    print("[CLK] UART clock divider set to ")
    print(div)
    print("\n")

proc clkgen_set_sd_div(div):
    clkgen_write32(CLKGEN_SD_CLK_DIV, div & 0xFF)
    print("[CLK] SD clock divider set to ")
    print(div)
    print("\n")
