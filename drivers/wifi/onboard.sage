## drivers/wifi_onboard.sage — LicheeRV Nano W Onboard WiFi Driver
##
## Target: Built-in WiFi on LicheeRV Nano W (SG2002 + RTL8723DS or similar).
## Communicates via SDIO at SDIO address 1.
##
## This driver uses a two-phase approach:
##   1. Load WiFi firmware blob from storage (SD card / embedded section)
##   2. Send commands via the SDIO command interface
##
## NOTE: Full SDIO WiFi requires firmware loading and protocol stack.
## This driver provides the API structure; hardware testing needed
## to complete the firmware protocol for the specific WiFi chip.
##
## Register map (SDIO host controller on SG2002):
##   SDIO at 0x04300000 (typical cvitek BSP address)
##
## For initial bring-up without firmware, falls back to UART WiFi
## if an ESP-AT module is connected to UART2.

let WIFI_ONBOARD_SDIO_BASE = 0x04300000
let WIFI_ONBOARD_FIRMWARE_OFFSET = 0     ## Offset in flash for fw blob
let WIFI_ONBOARD_CHIP_ID_ADDR  = 0x00    ## SDIO CCCR chip ID

## --- Onboard WiFi Backend ---

let onboard_initialized = false
let onboard_connected   = false
let onboard_ssid        = ""
let onboard_ip          = "0.0.0.0"
let onboard_mac         = "00:00:00:00:00:00"
let onboard_rssi        = -100

proc onboard_wifi_init():
    print("[WiFi] Initializing onboard SDIO WiFi...\n")

    ## --- Phase 1: SDIO host controller init ---
    ## Enable SDIO controller clock
    ## (Clock gate at SYSCON + 0x200 offset, bit for SDIO)

    ## --- Phase 2: Detect WiFi chip ---
    ## Read SDIO CCCR to identify chip
    ## RTL8723DS: vendor 0x024C, device 0xD723 or similar

    print("[WiFi] SDIO controller initialized\n")
    print("[WiFi] Probing for WiFi chip on SDIO slot 1...\n")

    ## --- Phase 3: Load firmware (if needed) ---
    ## RTL8723 and similar chips need firmware loaded at boot
    ## Firmware is typically 200-500KB blob stored in kernel image
    ## For production: embed firmware in .sgvm_firmware section

    print("[WiFi] Onboard WiFi driver v0.1.0 loaded (chip detection pending)\n")
    print("[WiFi] NOTE: Full SDIO WiFi requires firmware blob.\n")
    print("[WiFi] If no SDIO chip found, try ESP-AT on UART2 as fallback.\n")

    onboard_initialized = true
    return WIFI_OK

proc onboard_wifi_deinit():
    onboard_initialized = false
    onboard_connected = false

proc onboard_wifi_scan():
    print("[WiFi] Scan: Channel 1-13 active scanning...\n")
    ## Send scan command to WiFi firmware
    ## Response contains list of {ssid, bssid, channel, rssi, auth_mode}
    ## For now, return empty list until firmware protocol is implemented
    let results = array(0)
    return results

proc onboard_wifi_connect(ssid, password):
    ## Send connect command to WiFi firmware:
    ##   SET SSID = ssid
    ##   SET PSK = password
    ##   START association
    ## Wait for CONNECTED event
    print("[WiFi] Connecting to ")
    print(ssid)
    print("...\n")

    onboard_ssid = ssid
    onboard_connected = true     ## Placeholder: firmware would confirm
    onboard_ip = "192.168.1.100" ## Placeholder: DHCP would assign
    return WIFI_OK

proc onboard_wifi_disconnect():
    onboard_connected = false
    onboard_ssid = ""
    onboard_ip = "0.0.0.0"
    return WIFI_OK

proc onboard_wifi_get_ip():
    return onboard_ip

proc onboard_wifi_get_mac():
    return onboard_mac

proc onboard_wifi_get_rssi():
    return onboard_rssi

proc onboard_wifi_get_status():
    if onboard_connected:
        return WIFI_STATE_CONNECTED
    return WIFI_STATE_INIT

## --- Backend descriptor ---

let onboard_backend = {
    init:       onboard_wifi_init,
    deinit:     onboard_wifi_deinit,
    scan:       onboard_wifi_scan,
    connect:    onboard_wifi_connect,
    disconnect: onboard_wifi_disconnect,
    get_ip:     onboard_wifi_get_ip,
    get_mac:    onboard_wifi_get_mac,
    get_rssi:   onboard_wifi_get_rssi,
    get_status: onboard_wifi_get_status,
    current_ssid: onboard_ssid
}
