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

The LicheeRV Nano W features an onboard AIC8800D WiFi 6 and Bluetooth 5.2 chip connected via SDIO.
The driver initializes the SDIO bus, verifies the Vendor ID and Device ID, and then streams the proprietary `aic8800_fw.bin` firmware blob into the chip's RAM to boot its internal core. Once the firmware is running, the driver communicates with the chip using an IPC (Inter-Processor Communication) shared-memory protocol to execute networking commands like `wifi scan` and `wifi connect`.

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
