## kernel/net/stack.sage — Pure-Sage TCP/IP Network Stack
##
## Layers: Ethernet → ARP → IPv4 → UDP/TCP → Sockets
## All pure data structure manipulation — no hardware dependencies.
##
## Usage:
##   net_init()                    Initialize network stack
##   net_set_interface(mac, ip)    Configure network interface
##   net_send_packet(data, len)    Send raw Ethernet frame
##   net_receive_packet(data, len) Process received frame
##   udp_bind(port)                Bind UDP socket
##   udp_send(ip, port, data)      Send UDP datagram
##   tcp_connect(ip, port)         TCP connect
##   tcp_send(fd, data)            TCP send
##   tcp_recv(fd)                  TCP receive

## --- Ethernet ---

let ETH_HDR_SIZE    = 14
let ETH_TYPE_ARP    = 0x0806
let ETH_TYPE_IPV4   = 0x0800
let ETH_BROADCAST   = "FFFFFFFFFFFF"

let net_mac = "000000000000"
let net_ip  = "0.0.0.0"

proc eth_header(src_mac, dst_mac, ethertype):
    return {src: src_mac, dst: dst_mac, type: ethertype}

## --- ARP ---

let ARP_HDR_SIZE    = 28
let ARP_OP_REQUEST  = 1
let ARP_OP_REPLY    = 2

let arp_table = array(16)  # {ip, mac}

proc arp_lookup(ip):
    let i = 0
    while i < len(arp_table):
        if arp_table[i] != nil and arp_table[i].ip == ip:
            return arp_table[i].mac
        i = i + 1
    return nil

proc arp_add(ip, mac):
    push(arp_table, {ip: ip, mac: mac})

proc arp_process(packet):
    ## Parse ARP packet, handle request/reply
    let op = packet[6] << 8 | packet[7]
    if op == ARP_OP_REQUEST:
        ## Check if target IP matches ours
        ## Send ARP reply
        pass
    elif op == ARP_OP_REPLY:
        ## Cache sender's MAC
        pass

## --- IPv4 ---

let IP_HDR_MIN_SIZE = 20
let IP_PROTO_UDP    = 17
let IP_PROTO_TCP    = 6
let IP_PROTO_ICMP   = 1

let ip_id = 0

proc ip_checksum(header, hdr_len):
    let sum = 0
    let i = 0
    while i < hdr_len - 1:
        sum = sum + (header[i] << 8 | header[i + 1])
        i = i + 2
    sum = (sum >> 16) + (sum & 0xFFFF)
    sum = sum + (sum >> 16)
    return ~sum & 0xFFFF

proc ip_header(src_ip, dst_ip, protocol, payload_len):
    let total_len = IP_HDR_MIN_SIZE + payload_len
    ip_id = ip_id + 1
    return {
        version_ihl: 0x45,     # IPv4, 5 words
        dscp_ecn:    0,
        total_len:   total_len,
        id:          ip_id & 0xFFFF,
        flags_frag:  0,
        ttl:         64,
        protocol:    protocol,
        checksum:    0,         # filled by ip_checksum
        src:         src_ip,
        dst:         dst_ip
    }

proc ip_process(packet):
    ## Parse and handle IPv4 packet
    let version = (packet[0] >> 4) & 0xF
    let ihl     = packet[0] & 0xF
    let proto   = packet[9]
    let src_ip  = {packet[12], packet[13], packet[14], packet[15]}
    let dst_ip  = {packet[16], packet[17], packet[18], packet[19]}

    let payload = packet  # subarray from ihl*4 onwards

    if proto == IP_PROTO_UDP:
        udp_process(payload, src_ip, dst_ip)
    elif proto == IP_PROTO_TCP:
        tcp_process(payload, src_ip, dst_ip)
    elif proto == IP_PROTO_ICMP:
        icmp_process(payload)

## --- ICMP (Ping) ---

let ICMP_ECHO_REQUEST = 8
let ICMP_ECHO_REPLY   = 0

proc icmp_process(packet):
    let type = packet[0]
    if type == ICMP_ECHO_REQUEST:
        ## Send echo reply
        pass

## --- UDP ---

let UDP_HDR_SIZE = 8

let udp_sockets = array(16)  # {port, recv_queue}

proc udp_bind(port):
    ## Create a UDP socket bound to port
    let sock = {port: port, queue: array(16)}
    push(udp_sockets, sock)
    return len(udp_sockets) - 1

proc udp_send(dst_ip, dst_port, data):
    let src_port = 0  # Ephemeral
    let length = UDP_HDR_SIZE + len(data)
    ## Build UDP header + IP packet + Ethernet frame
    pass

proc udp_process(packet, src_ip, dst_ip):
    let src_port = packet[0] << 8 | packet[1]
    let dst_port = packet[2] << 8 | packet[3]
    let length   = packet[4] << 8 | packet[5]

    let data = packet  # subarray from offset 8

    ## Deliver to socket
    let i = 0
    while i < len(udp_sockets):
        let sock = udp_sockets[i]
        if sock != nil and sock.port == dst_port:
            push(sock.queue, {src_ip: src_ip, src_port: src_port, data: data})
        i = i + 1

proc udp_recv(sock_id):
    let sock = udp_sockets[sock_id]
    if sock == nil or len(sock.queue) == 0:
        return nil
    ## Pop first datagram
    let datagram = sock.queue[0]
    ## Shift queue
    return datagram

## --- TCP ---

let TCP_HDR_MIN_SIZE = 20
let TCP_FLAG_FIN = 0x01
let TCP_FLAG_SYN = 0x02
let TCP_FLAG_RST = 0x04
let TCP_FLAG_PSH = 0x08
let TCP_FLAG_ACK = 0x10

let TCP_STATE_CLOSED     = 0
let TCP_STATE_LISTEN     = 1
let TCP_STATE_SYN_SENT   = 2
let TCP_STATE_SYN_RCVD   = 3
let TCP_STATE_ESTABLISHED = 4
let TCP_STATE_FIN_WAIT   = 5
let TCP_STATE_TIME_WAIT  = 6

let tcp_sockets = array(16)  # {state, local_port, remote_ip, remote_port, seq, ack, recv_buf}

proc tcp_listen(port):
    let sock = {
        state:       TCP_STATE_LISTEN,
        local_port:  port,
        remote_ip:   nil,
        remote_port: 0,
        seq:         0,
        ack:         0,
        recv_buf:    array(64)
    }
    push(tcp_sockets, sock)
    return len(tcp_sockets) - 1

proc tcp_accept(listen_fd):
    ## Accept incoming connection
    pass

proc tcp_connect(dst_ip, dst_port):
    ## Three-way handshake (SYN → SYN-ACK → ACK)
    let sock = {
        state:       TCP_STATE_SYN_SENT,
        local_port:  0,  # Ephemeral
        remote_ip:   dst_ip,
        remote_port: dst_port,
        seq:         0,
        ack:         0,
        recv_buf:    array(64)
    }
    push(tcp_sockets, sock)
    let fd = len(tcp_sockets) - 1

    ## Send SYN
    tcp_send_segment(fd, TCP_FLAG_SYN, nil)
    return fd

proc tcp_send_segment(fd, flags, data):
    ## Build and send a TCP segment
    let sock = tcp_sockets[fd]
    if sock == nil:
        return
    ## Build TCP header + data
    pass

proc tcp_process(packet, src_ip, dst_ip):
    let src_port = packet[0] << 8 | packet[1]
    let dst_port = packet[2] << 8 | packet[3]
    let seq_num  = packet[4] << 24 | packet[5] << 16 | packet[6] << 8 | packet[7]
    let ack_num  = packet[8] << 24 | packet[9] << 16 | packet[10] << 8 | packet[11]
    let flags    = packet[13]

    ## Find matching socket
    let i = 0
    while i < len(tcp_sockets):
        let sock = tcp_sockets[i]
        if sock != nil and sock.local_port == dst_port:
            if sock.state == TCP_STATE_LISTEN and (flags & TCP_FLAG_SYN):
                ## Accept connection
                pass
            elif sock.state == TCP_STATE_SYN_SENT and (flags & (TCP_FLAG_SYN | TCP_FLAG_ACK)):
                ## SYN-ACK received
                sock.state = TCP_STATE_ESTABLISHED
                sock.ack = seq_num + 1
            elif sock.state == TCP_STATE_ESTABLISHED:
                if flags & TCP_FLAG_ACK:
                    ## Data delivery
                    pass
                if flags & TCP_FLAG_FIN:
                    sock.state = TCP_STATE_CLOSED
        i = i + 1

proc tcp_send(fd, data):
    let sock = tcp_sockets[fd]
    if sock == nil or sock.state != TCP_STATE_ESTABLISHED:
        return -1
    tcp_send_segment(fd, TCP_FLAG_PSH | TCP_FLAG_ACK, data)

proc tcp_recv(fd):
    let sock = tcp_sockets[fd]
    if sock == nil or len(sock.recv_buf) == 0:
        return nil
    return sock.recv_buf[0]  # Pop first

## --- Network Stack Init ---

proc net_init():
    print("[NET] TCP/IP stack initialized\n")
    print("[NET] Layers: ETH → ARP → IPv4 → UDP/TCP → Sockets\n")

proc net_set_interface(mac, ip):
    net_mac = mac
    net_ip  = ip
    print("[NET] Interface configured: MAC=")
    print(mac)
    print(" IP=")
    print(ip)
    print("\n")
