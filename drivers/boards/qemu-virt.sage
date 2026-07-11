## drivers/boards/qemu-virt.sage — QEMU RISC-V virt Board Support Package
##
## Provides board init for the QEMU virt machine.
## Used as a symmetric counterpart to licheerv.sage.

let BOARD_NAME    = "QEMU RISC-V 64 virt"
let BOARD_SOC     = "QEMU virt"
let BOARD_CPU     = "rv64imac"
let BOARD_RAM_MB  = 128
let BOARD_TIMER_HZ = 10000000
let BOARD_WIFI    = "none (virtio-net)"
let BOARD_WIFI_IF = "virtio-net-pci"

let UART_BASE     = 0x10000000
let PLIC_BASE     = 0x0C000000

proc board_init():
    print("[INIT] QEMU RISC-V 64 virt Board Support Package\n")
    print("  Machine: QEMU virt\n")
    print("  CPU:     rv64imac\n")
    print("  RAM:     128 MB\n")
    print("  UART:    16550A @ 0x10000000\n")
    print("  PLIC:    @ 0x0C000000\n")
    print("\n")
    uart_init(UART_BASE)
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
