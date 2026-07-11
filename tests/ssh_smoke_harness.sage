## tests/ssh_smoke_harness.sage — end-to-end ssh command smoke test
##
## Concatenated as: kernel/net/tcp_stack.sage + THIS + tools/bin/ssh_main.sage
## and run with the host `sage` interpreter.  Provides a software "SSH
## server" peer and overrides the loopback TX so every client segment is
## answered instantly, exercising the real ssh command flow.

let net_backend = "kernel"
let net_our_ip  = ip_aton("10.0.2.15")
let net_our_mac = [0x52, 0x55, 0x0A, 0x00, 0x00, 0x01]

let peer_mac   = [0x52, 0x55, 0x0A, 0x00, 0x00, 0x02]
let peer_ip    = ip_aton("127.0.0.1")
let peer_port  = 22
let peer_iss   = 0x2000
let peer_snd_nxt = 0
let peer_rcv_nxt = 0

proc peer_pop_tx():
    if len(loop_tx_q) == 0: return nil
    let f = loop_tx_q[0]
    let i = 0
    while i < len(loop_tx_q) - 1:
        loop_tx_q[i] = loop_tx_q[i + 1]
        i = i + 1
    pop(loop_tx_q)
    return f

proc peer_send_tcp(dsts, dstip, sport, dport, seq, ack, flags, payload):
    let seg = tcp_build(sport, dport, seq, ack, flags, 65535, payload)
    let c = tcp_checksum(peer_ip, dstip, seg)
    seg[16] = (c >> 8) & 0xFF
    seg[17] = c & 0xFF
    let ipp = ipv4_build(peer_ip, dstip, IP_PROTO_TCP, seg)
    push(loop_rx_q, eth_build(dsts, peer_mac, ETH_TYPE_IPV4, ipp))

proc peer_tick():
    let g = 0
    while len(loop_tx_q) > 0 and g < 64:
        g = g + 1
        let frame = peer_pop_tx()
        if frame == nil: break
        let eth = eth_parse(frame)
        if eth["type"] == ETH_TYPE_ARP:
            let p = eth["payload"]
            if get_u16(p, 6) == ARP_OP_REQUEST and get_u32(p, 24) == peer_ip:
                let sha = [p[8], p[9], p[10], p[11], p[12], p[13]]
                let spa = get_u32(p, 14)
                let reply = arp_build(ARP_OP_REPLY, peer_mac, peer_ip, sha, spa)
                push(loop_rx_q, eth_build(sha, peer_mac, ETH_TYPE_ARP, reply))
            continue
        if eth["type"] != ETH_TYPE_IPV4: continue
        let ip = ipv4_parse(eth["payload"])
        if ip["proto"] != IP_PROTO_TCP: continue
        let p = tcp_parse(ip["payload"])
        let our_sport = p["sport"]
        let our_seq = p["seq"]
        if (p["flags"] & TCP_SYN) and not (p["flags"] & TCP_ACK):
            peer_snd_nxt = seq_add(peer_iss, 1)
            peer_send_tcp(eth["src"], ip["src"], peer_port, our_sport,
                          peer_iss, seq_add(our_seq, 1), TCP_SYN | TCP_ACK, [])
            continue
        if (p["flags"] & TCP_FIN):
            peer_rcv_nxt = seq_add(our_seq, 1)
            peer_send_tcp(eth["src"], ip["src"], peer_port, our_sport,
                          peer_snd_nxt, peer_rcv_nxt, TCP_FIN | TCP_ACK, [])
            continue
        if (p["flags"] & TCP_ACK) and len(p["data"]) > 0:
            peer_rcv_nxt = seq_add(our_seq, len(p["data"]))
            let banner = []
            let bs = "SSH-2.0-OpenSSH_9.6\r\n"
            let k = 0
            while k < len(bs):
                push(banner, ord(bs[k]))
                k = k + 1
            peer_send_tcp(eth["src"], ip["src"], peer_port, our_sport,
                          peer_snd_nxt, peer_rcv_nxt, TCP_PSH | TCP_ACK, banner)
            peer_snd_nxt = seq_add(peer_snd_nxt, len(banner))

## Drive the peer synchronously: every client segment gets an immediate reply.
proc netdev_tx(frame):
    push(loop_tx_q, frame)
    peer_tick()

proc netdev_rx():
    return queue_shift(loop_rx_q)

proc netdev_now():
    return net_clock

## argv() builtin, normally supplied by the kernel.
proc argv():
    return "127.0.0.1"

## streq() builtin, supplied by the kernel on the embedded VM.
proc streq(a, b):
    if a == nil or b == nil:
        if a == nil and b == nil: return true
        return false
    if len(a) != len(b): return false
    let i = 0
    while i < len(a):
        if a[i] != b[i]: return false
        i = i + 1
    return true
