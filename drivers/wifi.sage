## drivers/wifi.sage — Pure-Sage WiFi Driver Abstraction Layer
##
## Provides a hardware-independent WiFi interface.
## Backend implementations: wifi_espat (ESP-AT), wifi_sdio (SDIO WiFi)
##
## Usage:
##   import wifi
##   wifi.init(backend)
##   wifi.scan()           → list of {ssid, rssi, channel}
##   wifi.connect(ssid, password)
##   wifi.get_ip()         → "192.168.1.x"
##   wifi.disconnect()

## --- WiFi Status Codes ---

let WIFI_OK              = 0
let WIFI_ERR_TIMEOUT     = 1
let WIFI_ERR_AUTH        = 2
let WIFI_ERR_NETWORK     = 3
let WIFI_ERR_HARDWARE    = 4
let WIFI_ERR_NOT_INIT    = 5
let WIFI_ERR_ALREADY_CONN = 6

## --- WiFi Connection State ---

let WIFI_STATE_OFF        = 0
let WIFI_STATE_INIT       = 1
let WIFI_STATE_SCANNING   = 2
let WIFI_STATE_CONNECTING = 3
let WIFI_STATE_CONNECTED  = 4
let WIFI_STATE_ERROR      = 5

## --- Backend Interface ---
##
## Each backend must provide:
##   backend.init()              → error code
##   backend.deinit()
##   backend.scan()              → list of network dicts
##   backend.connect(ssid, pwd)  → error code
##   backend.disconnect()        → error code
##   backend.get_ip()            → IP string
##   backend.get_status()        → connection state
##   backend.get_mac()           → MAC string
##   backend.get_rssi()          → signal strength (dBm)

## --- WiFi Driver State ---

let wifi_backend = nil
let wifi_state = WIFI_STATE_OFF
let wifi_last_error = WIFI_OK

## --- Public API ---

proc wifi_init(backend):
    wifi_backend = backend
    let err = backend.init()
    if err == WIFI_OK:
        wifi_state = WIFI_STATE_INIT
    else:
        wifi_state = WIFI_STATE_ERROR
        wifi_last_error = err
    return err

proc wifi_scan():
    if wifi_state < WIFI_STATE_INIT:
        wifi_last_error = WIFI_ERR_NOT_INIT
        return nil
    wifi_state = WIFI_STATE_SCANNING
    let results = wifi_backend.scan()
    wifi_state = WIFI_STATE_INIT
    return results

proc wifi_connect(ssid, password):
    if wifi_state < WIFI_STATE_INIT:
        wifi_last_error = WIFI_ERR_NOT_INIT
        return WIFI_ERR_NOT_INIT
    wifi_state = WIFI_STATE_CONNECTING
    let err = wifi_backend.connect(ssid, password)
    if err == WIFI_OK:
        wifi_state = WIFI_STATE_CONNECTED
    else:
        wifi_state = WIFI_STATE_ERROR
        wifi_last_error = err
    return err

proc wifi_disconnect():
    if wifi_backend != nil:
        wifi_backend.disconnect()
    wifi_state = WIFI_STATE_INIT

proc wifi_get_ip():
    if wifi_state != WIFI_STATE_CONNECTED:
        return "0.0.0.0"
    return wifi_backend.get_ip()

proc wifi_get_mac():
    if wifi_backend == nil:
        return "00:00:00:00:00:00"
    return wifi_backend.get_mac()

proc wifi_get_rssi():
    if wifi_backend == nil:
        return -100
    return wifi_backend.get_rssi()

proc wifi_get_state():
    return wifi_state

proc wifi_get_status_text():
    if wifi_state == WIFI_STATE_OFF:
        return "OFF"
    if wifi_state == WIFI_STATE_INIT:
        return "INITIALIZED"
    if wifi_state == WIFI_STATE_SCANNING:
        return "SCANNING"
    if wifi_state == WIFI_STATE_CONNECTING:
        return "CONNECTING"
    if wifi_state == WIFI_STATE_CONNECTED:
        return "CONNECTED"
    if wifi_state == WIFI_STATE_ERROR:
        return "ERROR"
    return "UNKNOWN"

proc wifi_is_connected():
    return wifi_state == WIFI_STATE_CONNECTED

proc wifi_print_status():
    print("\n")
    print("  WiFi Status: ")
    print(wifi_get_status_text())
    print("\n")
    if wifi_state == WIFI_STATE_CONNECTED:
        print("  SSID:    ")
        print(wifi_backend.current_ssid)
        print("\n")
        print("  IP:      ")
        print(wifi_get_ip())
        print("\n")
        print("  MAC:     ")
        print(wifi_get_mac())
        print("\n")
        print("  RSSI:    ")
        print(wifi_get_rssi())
        print(" dBm\n")
    if wifi_state == WIFI_STATE_ERROR:
        print("  Error:   ")
        print(wifi_last_error)
        print("\n")
    print("\n")
