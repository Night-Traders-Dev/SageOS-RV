## kernel/net/wifi_net.sage — WiFi Network Interface Integration
##
## Bridges the WiFi driver to the TCP/IP network stack.
## Converts WiFi scan/connect results to network interface config.
## Handles DHCP after WiFi connection.

proc wifi_net_connect(ssid, password):
    print("[WiFi-NET] Connecting to ")
    print(ssid)
    print("...\n")

    ## 1. Connect via AIC8800 driver
    aic_wifi_connect(ssid, password)

    ## 2. Wait for connection
    print("[WiFi-NET] Waiting for association...\n")

    ## 3. Get MAC address
    net_mac = aic_wifi_get_mac()
    print("[WiFi-NET] MAC: ")
    print(net_mac)
    print("\n")

    ## 4. DHCP — get IP address
    print("[WiFi-NET] Starting DHCP...\n")
    dhcp_discover()

    ## 5. Wait for DHCP bound
    ## In real impl: poll with timeout
    print("[WiFi-NET] Waiting for DHCP lease...\n")

    if dhcp_bound():
        net_set_interface(net_mac, dhcp_get_ip())
        print("[WiFi-NET] Connected: ")
        print(dhcp_get_ip())
        print("\n")
        return true

    print("[WiFi-NET] DHCP timeout\n")
    return false

proc wifi_net_scan():
    print("[WiFi-NET] Scanning...\n")
    let networks = aic_wifi_scan()
    print("[WiFi-NET] Networks found:\n")
    let i = 0
    while i < len(networks):
        let net = networks[i]
        if net != nil:
            print("  "); print(net.ssid)
            print(" ("); print(net.rssi); print(" dBm)\n")
        i = i + 1

proc wifi_net_init():
    print("[WiFi-NET] Initializing WiFi network interface\n")
    net_init()
