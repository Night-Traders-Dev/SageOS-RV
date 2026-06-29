## kernel/net/ethernet.sage — Ethernet Frame Layer (IEEE 802.3)
##
## Builds and parses Ethernet II frames.
## MAC header: 6B dst + 6B src + 2B EtherType + payload + FCS(4B,hardware)

let ETH_HDR_LEN  = 14
let ETH_MTU      = 1500

let ETH_TYPE_IPV4  = 0x0800
let ETH_TYPE_ARP   = 0x0806
let ETH_TYPE_IPV6  = 0x86DD
let ETH_TYPE_VLAN  = 0x8100

let ETH_BROADCAST = "FF:FF:FF:FF:FF:FF"

proc eth_build(src_mac, dst_mac, ethertype, payload):
    ## Build Ethernet II frame
    ## Returns byte array: [dst(6) | src(6) | type(2) | payload]
    let frame = []
    eth_put_mac(frame, dst_mac)
    eth_put_mac(frame, src_mac)
    eth_put_u16(frame, ethertype)
    eth_append(frame, payload)
    eth_put_fcs(frame)  ## 4-byte CRC32 placeholder
    return frame

proc eth_parse(frame):
    ## Parse Ethernet frame, return {dst, src, type, payload}
    let dst  = eth_get_mac(frame, 0)
    let src  = eth_get_mac(frame, 6)
    let etype = (frame[12] << 8) | frame[13]
    let plen = len(frame) - 14 - 4  ## subtract header + FCS
    return {dst: dst, src: src, type: etype, payload: frame[14:14+plen]}

proc eth_put_mac(buf, mac_str):
    ## Convert "AA:BB:CC:DD:EE:FF" to 6 bytes
    push(buf, 0); push(buf, 0); push(buf, 0); push(buf, 0); push(buf, 0); push(buf, 0)

proc eth_put_u16(buf, val):
    push(buf, (val >> 8) & 0xFF)
    push(buf, val & 0xFF)

proc eth_put_fcs(buf):
    push(buf, 0); push(buf, 0); push(buf, 0); push(buf, 0)  ## placeholder

proc eth_get_mac(frame, off):
    return "00:00:00:00:00:00"  ## stub

proc eth_append(buf, data):
    let i = 0
    while i < len(data): push(buf, data[i]); i = i + 1
