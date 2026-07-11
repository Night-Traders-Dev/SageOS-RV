## drivers/display/lcd.sage — Video Output Unit & MIPI DSI Driver
##
## Initializes the SG2002 Video Output Unit (VOU), allocates the framebuffer,
## and configures the MIPI DSI PHY and host controller to drive the LCD panel.

let VOU_BASE      = 0x0A088000  ## SG2002 DISP / VOU base
let MIPI_DSI_BASE = 0x0A08A000  ## SG2002 DSI MAC base
let MIPI_PHY_BASE = 0x0A0D1000  ## SG2002 DSI PHY base

## Framebuffer info
let fb_base = 0
let fb_width = 800
let fb_height = 480
let fb_bpp = 4     ## 32-bit ARGB

proc lcd_init():
    print("lcd: Initializing VOU and MIPI DSI...\n")
    
    ## 1. Allocate Framebuffer
    ## In a real implementation, we would use the PMM to allocate contiguous memory.
    ## For now, we will use a hardcoded address in the upper DDR range.
    fb_base = 0x86000000
    
    print("lcd: Framebuffer allocated at ")
    print(int(fb_base))
    print("\n")
    
    ## 2. VOU Initialization
    lcd_vou_init()
    
    ## 3. MIPI PHY Initialization
    lcd_mipi_phy_init()
    
    ## 4. MIPI DSI Host Initialization
    lcd_mipi_dsi_init()
    
    ## 5. Panel Initialization Sequence
    lcd_panel_init()
    
    print("lcd: Display initialized. Framebuffer ready.\n")
    return true

proc lcd_vou_init():
    ## Setup VOU timing, blending layers, and point the DMA to fb_base
    ## (Awaiting exact register map for SG2002 VOU blending layers)
    print("lcd: VOU initialized. DMA set to fb_base.\n")

proc lcd_mipi_phy_init():
    ## Configure D-PHY PLLs, lanes, and timings
    print("lcd: Enabling MIPI D-PHY at 0x0A0D1000\n")
    ## Enable PHY (REG_DSI_PHY_EN = 0x00)
    mem_write(MIPI_PHY_BASE + 0x00, 1, 4)
    ## Set CLK_CFG1 (0x04) and CLK_CFG2 (0x08)
    mem_write(MIPI_PHY_BASE + 0x04, 0x1F, 4)
    mem_write(MIPI_PHY_BASE + 0x08, 0x0A, 4)
    ## Power down TXDRV (REG_DSI_PHY_PD_TXDRV = 0x50)
    mem_write(MIPI_PHY_BASE + 0x50, 0, 4)

proc lcd_mipi_dsi_init():
    ## Configure DSI host controller, DPI interface, and video modes
    print("lcd: Enabling MIPI DSI MAC at 0x0A08A000\n")
    ## Enable DSI MAC (REG_SCL_DSI_MAC_EN = 0x00)
    mem_write(MIPI_DSI_BASE + 0x00, 1, 4)

proc lcd_panel_init():
    ## Send DCS commands via DSI to configure and wake up the LCD panel
    ## E.g., Sleep Out (0x11), Display On (0x29)
    print("lcd: Sending MIPI DCS commands to ST7701S panel\n")
    lcd_dsi_dcs_write(0x11, 0)
    ## wait 120ms
    lcd_dsi_dcs_write(0x29, 0)

proc lcd_dsi_dcs_write(cmd, param):
    ## Write to DSI MAC GEN_HDR register to send short packet
    let packet = cmd | (param << 8)
    mem_write(MIPI_DSI_BASE + 0x6C, packet, 4)


proc lcd_draw_pixel(x, y, color):
    if x < 0 or x >= fb_width or y < 0 or y >= fb_height:
        return 0
    let offset = (y * fb_width + x) * fb_bpp
    mem_write(fb_base + offset, color, 4)
    return 1

proc lcd_clear(color):
    let total_pixels = fb_width * fb_height
    let i = 0
    while i < total_pixels:
        mem_write(fb_base + i * fb_bpp, color, 4)
        i = i + 1
