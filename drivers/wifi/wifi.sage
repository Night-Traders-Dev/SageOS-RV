## drivers/wifi/wifi.sage — WiFi Driver Abstraction Layer

let WIFI_OK     = 0
let WIFI_ERR    = 1

let WIFI_STATE_OFF        = 0
let WIFI_STATE_INIT       = 1
let WIFI_STATE_SCANNING   = 2
let WIFI_STATE_CONNECTING = 3
let WIFI_STATE_CONNECTED  = 4
let WIFI_STATE_ERROR      = 5

let wifi_state = WIFI_STATE_OFF

proc wifi_is_connected():
    return wifi_state == WIFI_STATE_CONNECTED

proc wifi_get_status():
    if wifi_state == WIFI_STATE_OFF:
        return "OFF"
    if wifi_state == WIFI_STATE_INIT:
        return "INIT"
    if wifi_state == WIFI_STATE_SCANNING:
        return "SCANNING"
    if wifi_state == WIFI_STATE_CONNECTING:
        return "CONNECTING"
    if wifi_state == WIFI_STATE_CONNECTED:
        return "CONNECTED"
    if wifi_state == WIFI_STATE_ERROR:
        return "ERROR"
    return "UNKNOWN"
