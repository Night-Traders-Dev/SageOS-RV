## drivers/wifi/aic8800.sage — AIC8800D WiFi 6 Driver
##
## Reference: aic8800_linux_drvier (IPC shared memory protocol)
## LicheeRV Nano W onboard AIC8800D over SDIO.

proc aic8800_init():
    print("[WiFi] AIC8800D driver placeholder\n")
    print("[WiFi] SDIO @ 0x04300000, IPC @ 0x87000000\n")
    return 0

proc aic8800_scan():
    print("[WiFi] Scan not yet implemented\n")
    return 0

proc aic8800_connect(ssid, pwd):
    print("[WiFi] Connect not yet implemented\n")
    return 0

proc aic8800_disconnect():
    return 0
