# SageOS-RV Hardware Drivers

This document outlines the pure-Sage drivers available for the supported hardware, specifically focusing on the LicheeRV Nano W (Sophgo SG2002) peripherals.

## SD/MMC Subsystem (DesignWare MSHC)

*   **File:** `kernel/hw/sdcard.sage`
*   **Target:** Synopsys DesignWare Mobile Storage Host Controller (DW-MSHC).
*   **Base Address (SG2002):** `0x04310000` (SDHCI0)

The SD/MMC driver provides block-level access to the microSD card. It handles the full initialization sequence (CMD0, CMD8, ACMD41) to power on and negotiate with the card. It uses CMD17 (READ_SINGLE_BLOCK) to pull 512-byte sectors out of the controller's FIFO. It also includes an MBR parser to discover partitions.

## SDIO Bus (DesignWare MSHC)

*   **File:** `drivers/bus/sdio.sage`
*   **Target:** Synopsys DesignWare Mobile Storage Host Controller (DW-MSHC) in SDIO mode.
*   **Base Address (SG2002):** `0x04320000` (SDHCI1)

The SDIO driver provides a transport layer for devices connected over SDIO (primarily the WiFi chip). It supports the CMD52 (Direct Byte Read/Write) command to interact with the device's Common Information Space (CIS) and configuration registers. 

## WiFi / Bluetooth (AIC8800)

*   **File:** `drivers/wifi/aic8800.sage`
*   **Firmware:** `drivers/wifi/firmware/aic8800_fw.bin`
*   **SDIO Base:** `0x04320000` (SDHCI1 on SG2002)
*   **IPC Base:** `0x87000000` (shared memory)

The LicheeRV Nano W features an onboard AIC8800D WiFi 6 and Bluetooth 5.2 chip connected via SDIO.
The driver initializes the SDIO bus, reads the Vendor/Device ID via CMD52, and enables SDIO Function 1. It checks for a firmware blob in the `.aic_fw` linker section (magic `0x46495741` = `"AWIF"`), or falls back to downloading via SDIO.

Once the firmware is running, the driver uses an IPC mailbox protocol over shared memory at `0x87000000`:

| Register | Offset | Purpose |
|---|---|---|
| `AIC_IPC_MBOX_CTRL` | `0x00` | Command trigger |
| `AIC_IPC_MBOX_TX` | `0x04` | Command argument |
| `AIC_IPC_MBOX_RX` | `0x08` | Response value |
| `AIC_IPC_MBOX_STS` | `0x0C` | Status flags (bit 0 = busy, bit 2 = response ready) |

Supported commands: `AIC_CMD_INIT`, `AIC_CMD_SCAN`, `AIC_CMD_CONNECT`, `AIC_CMD_DISCONNECT`, `AIC_CMD_GET_STATUS`. The driver also provides `aic8800_get_mac()` to read the MAC address from firmware.

## Display & Graphics (VOU / MIPI DSI)

*   **File:** `drivers/display/lcd.sage`
*   **Target:** Video Output Unit (VOU) and MIPI DSI Host/PHY
*   **Base Addresses (SG2002):**
    *   VOU/DISP: `0x0A088000`
    *   MIPI DSI MAC: `0x0A08A000`
    *   MIPI D-PHY: `0x0A0D1000`

This driver initializes the graphics pipeline for the LicheeRV Nano's default MIPI LCD panel (e.g. ST7701S).
It allocates a contiguous framebuffer in the DDR memory pool and configures the VOU DMA to scan out from that buffer.
It then brings up the MIPI D-PHY, configures the DSI MAC for High-Speed (HS) video transmission, and finally sends the manufacturer-specific DCS initialization commands over the DSI link to wake up the panel. Basic framebuffer manipulation functions (e.g., `lcd_draw_pixel`, `lcd_clear`) are provided for rendering.

## USB OTG (Synopsys DWC2)

*   **File:** `drivers/usb/dwc2.sage`
*   **Target:** Synopsys DesignWare Core (DWC2) USB 2.0 OTG Controller
*   **Base Address (SG2002):** `0x04340000`

This driver initializes the USB controller in Device Mode, allowing the LicheeRV Nano W to enumerate as a peripheral when plugged into a host PC.
It handles soft-resetting the core, enabling global interrupts, and configuring Endpoint 0 (EP0) for Control Transfers. An interrupt polling routine (`dwc2_poll`) is provided to handle USB Reset and Enumeration Done events from the host, correctly reading the negotiated link speed and re-arming EP0 to receive the subsequent SETUP packets (like Get Descriptor).

## Clock Generator (SG2002 CLKGEN)

*   **File:** `drivers/sys/clkgen.sage`
*   **Target:** SG2002 Clock Generator + PLLs
*   **Base Address (SG2002):** CLKGEN `0x03002000`, PLL `0x03001C00`

Manages the SG2002 clock tree: CPU, AXI, AHB, APB clock dividers and PLL control. Called during early board init to verify clock configuration. Provides `clkgen_set_uart_div()` and `clkgen_set_sd_div()` for peripheral clock adjustment.

## Power Management (AXP15060 PMIC)

*   **File:** `drivers/sys/pmic.sage`
*   **Target:** X-Powers AXP15060 (or compatible) via I2C0
*   **I2C Address:** `0x34`

Manages voltage rails for CPU core, DDR, IO, and WiFi via I2C0. Reads chip ID and status, enables power-on control, and provides `pmic_set_cpu_voltage(mv)` / `pmic_set_wifi_voltage(mv)` for dynamic voltage scaling.

## Board Support Packages

### LicheeRV Nano (`drivers/boards/licheerv.sage`)

Master BSP that orchestrates all SG2002 peripheral init:
1. `clkgen_init()` — clock tree
2. `uart_init(0x04140000)` — console
3. `i2c_init(0, 400000)` — I2C bus for PMIC
4. `pmic_init()` — power rails
5. `plic_init()` + `plic_enable_uart()` — interrupts

Also provides `wifi_init()`, `print_board_info()`, and onboard LED helpers (`led_init`, `led_on`, `led_off`, `led_blink`).

### QEMU virt (`drivers/boards/qemu-virt.sage`)

Symmetric board BSP for QEMU virt development:
- `uart_init(0x10000000)` — 16550A UART
- `plic_init(0x0C000000)` — PLIC interrupt controller
