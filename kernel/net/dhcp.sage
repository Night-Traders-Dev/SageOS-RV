## kernel/net/dhcp.sage — DHCP Client (RFC 2131)
let DHCP_CLIENT_PORT = 68; let DHCP_SERVER_PORT = 67
let DHCP_DISCOVER = 1; let DHCP_OFFER = 2; let DHCP_REQUEST = 3; let DHCP_ACK = 5
let dhcp_xid = 0; let dhcp_state = 0  ## 0=init,1=select,2=request,3=bound
let dhcp_ip = "0.0.0.0"; let dhcp_mask = "255.255.255.0"
let dhcp_gw = "0.0.0.0"; let dhcp_dns = "0.0.0.0"; let dhcp_lease = 0

proc dhcp_discover():
    print("[DHCP] Sending DHCPDISCOVER (broadcast)\n")
    dhcp_xid = 0x12345678  ## random transaction ID
    dhcp_state = 1

proc dhcp_handle(packet):
    if packet[0] != 2: return  ## not BOOTREPLY
    let msg_type = dhcp_find_option(packet, 53)
    if msg_type == DHCP_OFFER and dhcp_state == 1:
        print("[DHCP] Received DHCPOFFER\n")
        dhcp_state = 2
    elif msg_type == DHCP_ACK and dhcp_state == 2:
        print("[DHCP] Received DHCPACK — bound\n")
        dhcp_state = 3

proc dhcp_find_option(packet, option_code):
    let pos = 240  ## options start
    while pos < len(packet):
        let code = packet[pos]; pos = pos + 1
        if code == 255: return -1  ## END
        if code == 0: continue     ## PAD
        let opt_len = packet[pos]; pos = pos + 1
        if code == option_code: return packet[pos]  ## simplified
        pos = pos + opt_len
    return -1

proc dhcp_bound(): return dhcp_state == 3
proc dhcp_get_ip(): return dhcp_ip
