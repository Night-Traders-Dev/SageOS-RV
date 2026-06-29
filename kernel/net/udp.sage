## kernel/net/udp.sage — UDP Transport Layer (RFC 768)
let UDP_HDR_LEN = 8
proc udp_build(src_port, dst_port, payload):
    let datagram = []
    udp_put16(datagram, src_port)
    udp_put16(datagram, dst_port)
    udp_put16(datagram, 8 + len(payload))  ## length
    udp_put16(datagram, 0)  ## checksum (optional)
    let i = 0; while i < len(payload): push(datagram, payload[i]); i = i + 1
    return datagram
proc udp_parse(datagram):
    return { src_port: (datagram[0]<<8)|datagram[1], dst_port: (datagram[2]<<8)|datagram[3],
             len: (datagram[4]<<8)|datagram[5], payload: datagram[8:] }
proc udp_put16(buf, v): push(buf,(v>>8)&0xFF); push(buf,v&0xFF)
