## drivers/licheerv.sage — LicheeRV Nano Board Support Package
##
## Master driver include for the LicheeRV Nano (Sophgo SG2002).
## Imports all peripheral drivers and provides board init.
##
## Usage:
##   import licheerv
##   licheerv.board_init()     — Initialize all peripherals
##   licheerv.print_board_info() — Print board identification

## Board identification
let BOARD_NAME    = "LicheeRV Nano"
let BOARD_SOC     = "Sophgo SG2002"
let BOARD_CPU     = "T-Head C906 (rv64imafdc)"
let BOARD_RAM_MB  = 256
let BOARD_TIMER_HZ = 25000000

## --- Peripheral base addresses ---
let UART_BASE     = 0x04140000
let PLIC_BASE     = 0x0C000000
let GPIO0_BASE    = 0x03020000
let GPIO1_BASE    = 0x03021000
let I2C0_BASE     = 0x04000000
let I2C1_BASE     = 0x04010000
let SPI0_BASE     = 0x04180000
let WDT_BASE      = 0x03010000
let SYSCON_BASE   = 0x03001000

## --- Board Init ---

proc board_init():
    print("[INIT] LicheeRV Nano Board Support Package\n")
    print("  SoC:     Sophgo SG2002\n")
    print("  CPU:     C906 @ 1 GHz\n")
    print("  RAM:     256 MB DDR3\n")
    print("  UART:    16550A @ 0x04140000\n")
    print("  GPIO:    4 banks (128 pins)\n")
    print("  I2C:     3 controllers\n")
    print("  SPI:     2 controllers\n")
    print("\n")
    
    ## Initialize UART (console should already be up)
    uart_init(UART_BASE)
    
    ## Initialize PLIC for interrupt handling
    plic_init(PLIC_BASE)
    plic_enable_uart(PLIC_BASE)
    
    print("[OK] Board initialization complete.\n")

proc print_board_info():
    print("========================================\n")
    print("  Board:   ")
    print(BOARD_NAME)
    print("\n")
    print("  SoC:     ")
    print(BOARD_SOC)
    print("\n")
    print("  CPU:     ")
    print(BOARD_CPU)
    print("\n")
    print("  RAM:     ")
    print(BOARD_RAM_MB)
    print(" MB\n")
    print("========================================\n")

## --- Onboard LED ---
##
## LicheeRV Nano has a user LED on GPIO0 pin 14 (active low).
## Note: GPIO bank 0, not the pin numbering on the silkscreen.

proc led_init():
    gpio_init_output(GPIO0_BASE, 14, 1)

proc led_on():
    gpio_write(GPIO0_BASE, 14, 0)

proc led_off():
    gpio_write(GPIO0_BASE, 14, 1)

proc led_blink(count):
    let i = 0
    while i < count:
        led_on()
        delay_ms(200)
        led_off()
        delay_ms(200)
        i = i + 1
