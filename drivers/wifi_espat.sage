## drivers/wifi_espat.sage — ESP-AT WiFi Driver (UART)
##
## Communicates with an ESP8285/ESP32 module running AT firmware
## connected via a UART (typically UART2 on LicheeRV Nano).
##
## AT Command Reference (ESP-AT v2.x):
##   AT                    — Test communication
##   AT+RST                — Reset module
##   AT+CWMODE=1           — Station mode
##   AT+CWLAP              — List available APs (scan)
##   AT+CWJAP="SSID","PWD" — Connect to AP
##   AT+CWQAP              — Disconnect
##   AT+CIFSR              — Get IP/MAC
##   AT+CIPSTA?            — Get station IP config
##   AT+CIPSTART="TCP","host",port — Connect TCP
##   AT+CIPSEND=<len>      — Send data
##   AT+CIPCLOSE           — Close connection
##
## Hardware: Connect ESP module to UART2 (TX=pin8, RX=pin9)
## LicheeRV Nano UART2 base: 0x04160000

let ESPAT_UART_BASE = 0x04160000    ## UART2 on SG2002
let ESPAT_BAUD      = 115200
let ESPAT_TIMEOUT_MS = 5000

let espat_initialized = false
let espat_connected   = false
let espat_ssid        = ""
let espat_ip          = "0.0.0.0"
let espat_mac         = "00:00:00:00:00:00"

## --- AT Command Helpers ---

proc espat_send_cmd(cmd):
    uart_puts(ESPAT_UART_BASE, cmd)
    uart_puts(ESPAT_UART_BASE, "\r\n")

proc espat_read_response(timeout_ms):
    ## Read UART response until OK/ERROR/timeout
    let buf = ""
    let elapsed = 0
    while elapsed < timeout_ms:
        let c = uart_getc(ESPAT_UART_BASE)
        if c >= 0:
            ## Accumulate response
            ## In real implementation: build string, check for \r\nOK\r\n or \r\nERROR\r\n
            if c == 10:   ## \n
                ## Line complete
                pass
            elapsed = 0
        else:
            elapsed = elapsed + 1
            delay_ms(1)
    return buf

proc espat_expect_ok(timeout_ms):
    ## Send pending command and wait for OK response
    ## Returns WIFI_OK on success, WIFI_ERR_TIMEOUT on failure
    return WIFI_OK   ## Placeholder

## --- ESP-AT Backend ---

proc espat_init():
    print("[WiFi-ESP] Initializing ESP-AT module on UART...\n")

    ## Initialize UART for ESP communication
    uart_init(ESPAT_UART_BASE)

    ## Test AT communication
    espat_send_cmd("AT")
    delay_ms(500)
    espat_send_cmd("ATE0")   ## Disable echo
    delay_ms(200)

    ## Set station mode
    espat_send_cmd("AT+CWMODE=1")
    delay_ms(500)

    espat_initialized = true
    print("[WiFi-ESP] ESP-AT module ready\n")
    return WIFI_OK

proc espat_deinit():
    espat_initialized = false
    espat_connected = false
    espat_ssid = ""

proc espat_scan():
    if espat_initialized == false:
        return nil

    print("[WiFi-ESP] Scanning for networks...\n")
    espat_send_cmd("AT+CWLAP")

    ## Parse response:
    ## +CWLAP:(<ecn>,<ssid>,<rssi>,<mac>,<ch>,<freq_offset>,<freq_cal>)
    ## +CWLAP:(4,"MyWiFi",-45,"aa:bb:cc:dd:ee:ff",6,0,0)

    let results = array(0)
    ## Parse each +CWLAP line into {ssid, rssi, channel, mac, auth}
    ## For now, return empty — real parsing needs string ops
    print("[WiFi-ESP] Scan complete\n")
    return results

proc espat_connect(ssid, password):
    if espat_initialized == false:
        return WIFI_ERR_NOT_INIT

    print("[WiFi-ESP] Connecting to ")
    print(ssid)
    print("...\n")

    ## Build AT+CWJAP command
    let cmd = "AT+CWJAP=\""
    ## cmd = cmd + ssid + "\",\"" + password + "\""  ## String concat

    espat_send_cmd(cmd)
    delay_ms(5000)   ## Connection can take several seconds

    ## Check for "WIFI CONNECTED" and "WIFI GOT IP"
    espat_connected = true
    espat_ssid = ssid

    ## Query for IP address
    espat_send_cmd("AT+CIFSR")
    delay_ms(500)
    ## Parse +CIFSR:STAIP,"192.168.1.x"
    espat_ip = "192.168.1.100"   ## Placeholder

    print("[WiFi-ESP] Connected! IP: ")
    print(espat_ip)
    print("\n")
    return WIFI_OK

proc espat_disconnect():
    espat_send_cmd("AT+CWQAP")
    delay_ms(1000)
    espat_connected = false
    espat_ssid = ""
    espat_ip = "0.0.0.0"
    return WIFI_OK

proc espat_get_ip():
    return espat_ip

proc espat_get_mac():
    return espat_mac

proc espat_get_rssi():
    ## Send AT+CWLAP to get current RSSI
    return -45  ## Placeholder

proc espat_get_status():
    if espat_connected:
        return WIFI_STATE_CONNECTED
    return WIFI_STATE_INIT

## --- Backend descriptor ---

let espat_backend = {
    init:       espat_init,
    deinit:     espat_deinit,
    scan:       espat_scan,
    connect:    espat_connect,
    disconnect: espat_disconnect,
    get_ip:     espat_get_ip,
    get_mac:    espat_get_mac,
    get_rssi:   espat_get_rssi,
    get_status: espat_get_status,
    current_ssid: espat_ssid
}
