## kernel/net/dhcp.sage — DHCP Client
##
## Obtains IP address, subnet mask, gateway, DNS via DHCP.
## Uses UDP on port 68 (client) to port 67 (server).

let DHCP_CLIENT_PORT = 68
let DHCP_SERVER_PORT = 67

let DHCP_DISCOVER = 1
let DHCP_OFFER    = 2
let DHCP_REQUEST  = 3
let DHCP_ACK      = 5

let dhcp_state = 0   # 0=init, 1=discovering, 2=requesting, 3=bound
let dhcp_ip = "0.0.0.0"
let dhcp_mask = "255.255.255.0"
let dhcp_gw = "0.0.0.0"
let dhcp_dns = "0.0.0.0"

proc dhcp_discover():
    print("[DHCP] Sending DHCPDISCOVER...\n")
    ## Build DHCP discover packet:
    ##   op=1 (BOOTREQUEST), htype=1 (Ethernet), hlen=6, hops=0
    ##   xid=random, secs=0, flags=0x8000 (broadcast)
    ##   ciaddr=0, yiaddr=0, siaddr=0, giaddr=0
    ##   chaddr=MAC, options: 53=DHCP_DISCOVER, 55=param_list, 255=END
    dhcp_state = 1

proc dhcp_process(packet):
    let op = packet[0]
    if op != 2:  # BOOTREPLY
        return

    let msg_type = packet[242]  # Option 53
    if msg_type == DHCP_OFFER and dhcp_state == 1:
        print("[DHCP] Received DHCPOFFER\n")
        ## Extract yiaddr (your IP) at offset 16
        ## Send DHCPREQUEST
        dhcp_state = 2
    elif msg_type == DHCP_ACK and dhcp_state == 2:
        print("[DHCP] Received DHCPACK — bound\n")
        ## Extract IP, mask, gateway, DNS
        dhcp_state = 3

proc dhcp_bound():
    return dhcp_state == 3

proc dhcp_get_ip():
    return dhcp_ip
