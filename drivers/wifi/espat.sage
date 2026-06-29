## drivers/wifi/espat.sage — ESP-AT WiFi Driver (UART)
##
## Communicates with ESP8285/ESP32 via UART2 AT commands.

proc espat_init():
    print("[WiFi] ESP-AT module on UART2 placeholder\n")
    return 0

proc espat_scan():
    print("[WiFi] ESP-AT scan placeholder\n")
    return 0

proc espat_connect(ssid, pwd):
    print("[WiFi] ESP-AT connect placeholder\n")
    return 0

proc espat_disconnect():
    return 0
