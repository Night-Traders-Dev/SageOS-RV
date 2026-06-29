## drivers/wifi/onboard.sage — Generic Onboard SDIO WiFi Driver
##
## Placeholder for SDIO-based WiFi chips (RTL8723, etc.)

proc onboard_wifi_init():
    print("[WiFi] Onboard SDIO WiFi placeholder\n")
    return 0

proc onboard_wifi_scan():
    return 0

proc onboard_wifi_connect(ssid, pwd):
    return 0

proc onboard_wifi_disconnect():
    return 0
