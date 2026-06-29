## kernel/net/ipv4.sage — IPv4 Network Layer (RFC 791)
##
## Build/parse IPv4 packets. Handles fragmentation, checksums, routing.

let IP_HDR_MIN = 20
let IP_PROTO_ICMP = 1
let IP_PROTO_TCP   = 6
let IP_PROTO_UDP   = 17

let ip_id_counter = 0

proc ip_checksum(hdr, words):
    ## 16-bit one's complement sum over header words
    let sum = 0; let i = 0
    while i < words * 2:
        let w = (hdr[i] << 8) | hdr[i+1]
        sum = (sum + w) & 0xFFFFFFFF
        i = i + 2
    while sum > 0xFFFF: sum = (sum & 0xFFFF) + (sum >> 16)
    return (~sum) & 0xFFFF

proc ip_build(src_ip, dst_ip, protocol, payload):
    ## Build IPv4 packet: [ver|ihl|tos|len|id|flags|ttl|proto|cksum|src|dst|payload]
    let total_len = 20 + len(payload)
    ip_id_counter = ip_id_counter + 1
    let pkt = []
    ip_put_byte(pkt, 0x45)         ## Version 4, IHL 5 (20 bytes)
    ip_put_byte(pkt, 0)             ## DSCP/ECN
    ip_put_u16(pkt, total_len)      ## Total length
    ip_put_u16(pkt, ip_id_counter)  ## Identification
    ip_put_u16(pkt, 0)              ## Flags + Fragment offset
    ip_put_byte(pkt, 64)            ## TTL
    ip_put_byte(pkt, protocol)      ## Protocol
    ip_put_u16(pkt, 0)              ## Checksum (placeholder)
    ip_put_u32(pkt, src_ip)         ## Source IP
    ip_put_u32(pkt, dst_ip)         ## Dest IP
    ip_append(pkt, payload)         ## Payload
    ## Compute and insert checksum
    let cksum = ip_checksum(pkt, 10)
    pkt[10] = (cksum >> 8) & 0xFF; pkt[11] = cksum & 0xFF
    return pkt

proc ip_parse(pkt):
    ## Parse IPv4 packet, return {src, dst, proto, ttl, payload}
    let ver_ihl = pkt[0]
    let ihl = (ver_ihl & 0x0F) * 4
    return {
        ver:    (ver_ihl >> 4),
        ihl:    ihl,
        tos:    pkt[1],
        len:    (pkt[2]<<8)|pkt[3],
        id:     (pkt[4]<<8)|pkt[5],
        ttl:    pkt[8],
        proto:  pkt[9],
        src:    (pkt[12]<<24)|(pkt[13]<<16)|(pkt[14]<<8)|pkt[15],
        dst:    (pkt[16]<<24)|(pkt[17]<<16)|(pkt[18]<<8)|pkt[19],
        payload: pkt[ihl:]
    }

proc ip_put_byte(buf, b): push(buf, b & 0xFF)
proc ip_put_u16(buf, v): push(buf,(v>>8)&0xFF); push(buf,v&0xFF)
proc ip_put_u32(buf, v):
    push(buf,(v>>24)&0xFF); push(buf,(v>>16)&0xFF)
    push(buf,(v>>8)&0xFF); push(buf,v&0xFF)

proc ip_append(buf, data): let i=0; while i<len(data): push(buf,data[i]); i=i+1
