## kernel/net/tcp_stack.sage — Pure-Sage TCP/IP Transport Stack
##
## Self-contained, import-free implementation of the layers needed for a
## TCP connection to be established from SageOS-RV:
##
##   Ethernet (RFC 894) -> ARP (RFC 826) -> IPv4 (RFC 791) -> TCP (RFC 9293)
##
## The stack is transport-agnostic: it emits raw Ethernet frames through
## net_tx() and reads them back through net_rx().  Two backends are
## supported:
##   * "loopback" (default) — frames are queued in software so the stack can
##     be unit-tested on the host `sage` interpreter without any hardware.
##   * "kernel"   — net_tx()/net_rx() delegate to C VM builtins (knet_tx /
##     knet_rx) that drive a real NIC (e.g. QEMU virtio-net).
##
## Higher layers (ssh, curl, ping) call the socket API at the bottom.
##
## NOTE: This file must stay free of `import` so it can run inside the
## embedded RV64 VM, where OP_IMPORT is a no-op.  All dict keys are strings
## and accessed with ["key"] (the embedded VM has no property syntax).

## ---------------------------------------------------------------------------
## Byte / integer helpers
## ---------------------------------------------------------------------------

proc u8(v): return v & 0xFF

proc put_u16(buf, v):
    push(buf, (v >> 8) & 0xFF)
    push(buf, v & 0xFF)

proc put_u32(buf, v):
    push(buf, (v >> 24) & 0xFF)
    push(buf, (v >> 16) & 0xFF)
    push(buf, (v >> 8) & 0xFF)
    push(buf, v & 0xFF)

proc get_u16(buf, off):
    return ((buf[off] & 0xFF) << 8) | (buf[off + 1] & 0xFF)

proc get_u32(buf, off):
    return (((buf[off] & 0xFF) << 24) | ((buf[off + 1] & 0xFF) << 16) |
            ((buf[off + 2] & 0xFF) << 8) | (buf[off + 3] & 0xFF)) & 0xFFFFFFFF

## 32-bit sequence arithmetic (handles wraparound)
proc seq_add(a, b): return (a + b) & 0xFFFFFFFF
proc seq_sub(a, b): return (a - b) & 0xFFFFFFFF
proc seq_lt(a, b): return ((seq_sub(a, b)) & 0xFFFFFFFF) > 0x80000000

## ---------------------------------------------------------------------------
## IP / MAC address helpers
## ---------------------------------------------------------------------------

proc ip_aton(s):
    let parts = [0, 0, 0, 0]
    let cur = 0
    let i = 0
    while i < len(s):
        let c = ord(s[i])
        ## '.' (46) separates the octets
        if c == 46:
            cur = cur + 1
        else:
            parts[cur] = (parts[cur] * 10) + (c - 48)
        i = i + 1
    return (((parts[0] & 0xFF) << 24) | ((parts[1] & 0xFF) << 16) |
            ((parts[2] & 0xFF) << 8) | (parts[3] & 0xFF)) & 0xFFFFFFFF

proc ip_ntoa(ip):
    let a = (ip >> 24) & 0xFF
    let b = (ip >> 16) & 0xFF
    let c = (ip >> 8) & 0xFF
    let d = ip & 0xFF
    return str(a) + "." + str(b) + "." + str(c) + "." + str(d)

proc mac_eq(a, b):
    if len(a) != 6 or len(b) != 6: return false
    let i = 0
    while i < 6:
        if a[i] != b[i]: return false
        i = i + 1
    return true

proc mac_str(m):
    let s = ""
    let i = 0
    while i < 6:
        let h = m[i] & 0xFF
        let hi = (h >> 4) & 0xF
        let lo = h & 0xF
        s = s + str(hi) + str(lo)
        if i < 5: s = s + ":"
        i = i + 1
    return s

## ---------------------------------------------------------------------------
## Transport backend (pluggable)
## ---------------------------------------------------------------------------

let loop_tx_q     = []
let loop_rx_q     = []
## net_backend / net_our_mac / net_our_ip are supplied by the host harness
## (tests) or the kernel (embedded VM) before the stack is used, so they are
## not re-declared here (a re-declaration would clobber kernel-set values).
## net_clock / net_link_up are safe defaults (the kernel does not override
## them; kernel mode routes time via netdev_now()).
let net_clock     = 0
let net_link_up   = true

let net_debug     = false

proc net_dbg(s):
    if net_debug: print(s)

proc queue_shift(q):
    if len(q) == 0: return nil
    let f = q[0]
    let i = 0
    while i < (len(q) - 1):
        q[i] = q[i + 1]
        i = i + 1
    pop(q)
    return f

proc knet_tx(frame):
    ## On the embedded VM this name is provided by a C builtin (netdev_tx)
    ## that drives the real NIC.  On the host test harness it is overridden
    ## to feed a software peer.  Here we keep a loopback fallback so the
    ## stack never hard-fails if the backend is unavailable.
    push(loop_tx_q, frame)

proc knet_rx():
    return queue_shift(loop_rx_q)

proc net_tx(frame):
    if net_backend == "kernel": return netdev_tx(frame)
    push(loop_tx_q, frame)

proc net_rx():
    if net_backend == "kernel": return netdev_rx()
    return queue_shift(loop_rx_q)

proc net_now_ms():
    if net_backend == "kernel": return netdev_now()
    return net_clock

## ---------------------------------------------------------------------------
## Ethernet (RFC 894)
## ---------------------------------------------------------------------------

let ETH_TYPE_IPV4 = 0x0800
let ETH_TYPE_ARP  = 0x0806
let ETH_BROADCAST = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]

proc eth_build(dst, src, ethertype, payload):
    let f = []
    let i = 0
    while i < 6:
        push(f, dst[i] & 0xFF)
        i = i + 1
    i = 0
    while i < 6:
        push(f, src[i] & 0xFF)
        i = i + 1
    put_u16(f, ethertype)
    i = 0
    while i < len(payload):
        push(f, payload[i] & 0xFF)
        i = i + 1
    return f

proc eth_parse(frame):
    let dst = [frame[0], frame[1], frame[2], frame[3], frame[4], frame[5]]
    let src = [frame[6], frame[7], frame[8], frame[9], frame[10], frame[11]]
    let etype = get_u16(frame, 12)
    let payload = []
    let i = 14
    while i < len(frame):
        push(payload, frame[i])
        i = i + 1
    return {"dst": dst, "src": src, "type": etype, "payload": payload}

## ---------------------------------------------------------------------------
## ARP (RFC 826)
## ---------------------------------------------------------------------------

let ARP_OP_REQUEST = 1
let ARP_OP_REPLY   = 2

let arp_table = []

proc arp_lookup(ip):
    let i = 0
    while i < len(arp_table):
        if arp_table[i]["ip"] == ip: return arp_table[i]["mac"]
        i = i + 1
    return nil

proc arp_add(ip, mac):
    let i = 0
    while i < len(arp_table):
        if arp_table[i]["ip"] == ip:
            arp_table[i]["mac"] = mac
            return
        i = i + 1
    push(arp_table, {"ip": ip, "mac": mac})

proc arp_build(op, sha, spa, tha, tpa):
    let p = []
    put_u16(p, 1)
    put_u16(p, 0x0800)
    push(p, 6)
    push(p, 4)
    put_u16(p, op)
    let i = 0
    while i < 6:
        push(p, sha[i] & 0xFF)
        i = i + 1
    put_u32(p, spa)
    i = 0
    while i < 6:
        push(p, tha[i] & 0xFF)
        i = i + 1
    put_u32(p, tpa)
    return p

proc arp_request(target_ip):
    let pkt = arp_build(ARP_OP_REQUEST, net_our_mac, net_our_ip,
                        [0,0,0,0,0,0], target_ip)
    let frame = eth_build(ETH_BROADCAST, net_our_mac, ETH_TYPE_ARP, pkt)
    net_tx(frame)

proc arp_reply_for(frame):
    let p = frame["payload"]
    let op = get_u16(p, 6)
    if op == ARP_OP_REPLY:
        ## Someone answered our request: cache the mapping.
        let spa = get_u32(p, 14)
        let sha = [p[8], p[9], p[10], p[11], p[12], p[13]]
        arp_add(spa, sha)
        return
    if op != ARP_OP_REQUEST: return
    let tpa = get_u32(p, 24)
    if tpa != net_our_ip: return
    let spa = get_u32(p, 14)
    let sha = [p[8], p[9], p[10], p[11], p[12], p[13]]
    let reply = arp_build(ARP_OP_REPLY, net_our_mac, net_our_ip, sha, spa)
    let out = eth_build(sha, net_our_mac, ETH_TYPE_ARP, reply)
    net_tx(out)

## ---------------------------------------------------------------------------
## IPv4 (RFC 791)
## ---------------------------------------------------------------------------

let IP_PROTO_ICMP = 1
let IP_PROTO_TCP  = 6
let IP_PROTO_UDP  = 17

proc cksum16(bytes):
    let sum = 0
    let i = 0
    let n = len(bytes)
    while i + 1 < n:
        sum = sum + ((bytes[i] & 0xFF) << 8) + (bytes[i + 1] & 0xFF)
        i = i + 2
    if i < n:
        sum = sum + ((bytes[i] & 0xFF) << 8)
    while (sum >> 16) != 0:
        sum = (sum & 0xFFFF) + (sum >> 16)
    return (~sum) & 0xFFFF

proc ipv4_checksum(header):
    return cksum16(header)

proc ipv4_build(src_ip, dst_ip, proto, payload):
    let h = []
    push(h, 0x45)
    push(h, 0x00)
    put_u16(h, 20 + len(payload))
    put_u16(h, 0)
    put_u16(h, 0x4000)
    push(h, 64)
    push(h, proto & 0xFF)
    put_u16(h, 0)
    put_u32(h, src_ip)
    put_u32(h, dst_ip)
    let c = ipv4_checksum(h)
    h[10] = (c >> 8) & 0xFF
    h[11] = c & 0xFF
    let pkt = []
    let i = 0
    while i < 20:
        push(pkt, h[i])
        i = i + 1
    i = 0
    while i < len(payload):
        push(pkt, payload[i])
        i = i + 1
    return pkt

proc ipv4_parse(pkt):
    let ihl = (pkt[0] & 0xF) * 4
    let proto = pkt[9] & 0xFF
    let src = get_u32(pkt, 12)
    let dst = get_u32(pkt, 16)
    let payload = []
    let i = ihl
    while i < len(pkt):
        push(payload, pkt[i])
        i = i + 1
    return {"proto": proto, "src": src, "dst": dst, "payload": payload}

## ---------------------------------------------------------------------------
## TCP (RFC 9293)
## ---------------------------------------------------------------------------

let TCP_FIN = 0x01
let TCP_SYN = 0x02
let TCP_RST = 0x04
let TCP_PSH = 0x08
let TCP_ACK = 0x10

let TCP_CLOSED      = 0
let TCP_SYN_SENT    = 1
let TCP_SYN_RCVD    = 2
let TCP_ESTABLISHED = 3
let TCP_FIN_WAIT1   = 4
let TCP_FIN_WAIT2   = 5
let TCP_CLOSE_WAIT  = 6
let TCP_LAST_ACK    = 7
let TCP_TIME_WAIT   = 8

let TCP_STATE_NAMES = ["CLOSED", "SYN_SENT", "SYN_RCVD", "ESTABLISHED",
                       "FIN_WAIT1", "FIN_WAIT2", "CLOSE_WAIT", "LAST_ACK", "TIME_WAIT"]

let tcp_sockets = []
let tcp_ephemeral = 40000
let tcp_iss = 0x1000

proc tcp_checksum(src_ip, dst_ip, seg):
    let ph = []
    put_u32(ph, src_ip)
    put_u32(ph, dst_ip)
    push(ph, 0)
    push(ph, IP_PROTO_TCP)
    put_u16(ph, len(seg))
    let all = []
    let i = 0
    while i < len(ph):
        push(all, ph[i])
        i = i + 1
    i = 0
    while i < len(seg):
        push(all, seg[i])
        i = i + 1
    if (len(all) % 2) != 0: push(all, 0)
    return cksum16(all)

proc tcp_build(sport, dport, seq, ack, flags, window, payload):
    let seg = []
    put_u16(seg, sport)
    put_u16(seg, dport)
    put_u32(seg, seq)
    put_u32(seg, ack)
    push(seg, 0x50)
    push(seg, flags & 0xFF)
    put_u16(seg, window)
    put_u16(seg, 0)
    put_u16(seg, 0)
    let i = 0
    while i < len(payload):
        push(seg, payload[i] & 0xFF)
        i = i + 1
    return seg

proc tcp_finalize(src_ip, dst_ip, sport, dport, seq, ack, flags, window, payload):
    let seg = tcp_build(sport, dport, seq, ack, flags, window, payload)
    let c = tcp_checksum(src_ip, dst_ip, seg)
    seg[16] = (c >> 8) & 0xFF
    seg[17] = c & 0xFF
    let ip = ipv4_build(src_ip, dst_ip, IP_PROTO_TCP, seg)
    let dmac = arp_lookup(dst_ip)
    if dmac == nil: dmac = ETH_BROADCAST
    return eth_build(dmac, net_our_mac, ETH_TYPE_IPV4, ip)

proc tcp_parse(seg):
    return {
        "sport": get_u16(seg, 0),
        "dport": get_u16(seg, 2),
        "seq":   get_u32(seg, 4),
        "ack":   get_u32(seg, 8),
        "flags": seg[13] & 0xFF,
        "window": get_u16(seg, 14),
        "data": seg[20:]
    }

## ---------------------------------------------------------------------------
## Socket API
## ---------------------------------------------------------------------------

proc tcp_socket():
    tcp_iss = (tcp_iss + 0x1234) & 0xFFFFFFFF
    tcp_ephemeral = tcp_ephemeral + 1
    let tcb = {
        "state": TCP_CLOSED,
        "local_port": tcp_ephemeral,
        "remote_port": 0,
        "remote_ip": 0,
        "remote_mac": nil,
        "rcv_nxt": 0,
        "rcv_wnd": 0,
        "snd_una": tcp_iss,
        "snd_nxt": tcp_iss,
        "iss": tcp_iss,
        "window": 65535,
        "recv_buf": [],
        "send_buf": [],
        "retransmit_at": 0,
        "last_seg": nil,
        "pending_syn": false
    }
    push(tcp_sockets, tcb)
    return len(tcp_sockets) - 1

proc tcp_connect(fd, dst_ip, dst_port):
    let tcb = tcp_sockets[fd]
    if tcb == nil: return false
    tcb["remote_ip"] = dst_ip
    tcb["remote_port"] = dst_port
    let mac = arp_lookup(dst_ip)
    if mac == nil:
        arp_request(dst_ip)
        tcb["state"] = TCP_SYN_SENT
        tcb["pending_syn"] = true
        tcb["retransmit_at"] = net_now_ms() + 1000
        return true
    tcb["remote_mac"] = mac
    tcb["state"] = TCP_SYN_SENT
    tcb["snd_una"] = tcb["iss"]
    tcb["snd_nxt"] = seq_add(tcb["iss"], 1)
    let seg = tcp_finalize(net_our_ip, dst_ip, tcb["local_port"], dst_port,
                           tcb["iss"], 0, TCP_SYN, tcb["window"], [])
    tcb["last_seg"] = seg
    tcb["retransmit_at"] = net_now_ms() + 1000
    net_tx(seg)
    return true

proc tcp_send_ack(tcb):
    let seg = tcp_finalize(net_our_ip, tcb["remote_ip"], tcb["local_port"],
                           tcb["remote_port"], tcb["snd_nxt"], tcb["rcv_nxt"],
                           TCP_ACK, tcb["window"], [])
    net_tx(seg)

proc tcp_input(tcb, seg):
    let p = tcp_parse(seg)
    let flags = p["flags"]
    if tcb["state"] == TCP_SYN_SENT:
        if (flags & TCP_SYN) and (flags & TCP_ACK):
            tcb["rcv_nxt"] = seq_add(p["seq"], 1)
            tcb["snd_una"] = p["ack"]
            tcb["remote_mac"] = arp_lookup(tcb["remote_ip"])
            tcb["state"] = TCP_ESTABLISHED
            tcb["established"] = true
            tcb["last_seg"] = nil
            tcb["retransmit_at"] = 0
            tcp_send_ack(tcb)
            return
    elif tcb["state"] == TCP_ESTABLISHED:
        if (flags & TCP_FIN):
            tcb["rcv_nxt"] = seq_add(p["seq"], 1)
            tcp_send_ack(tcb)
            tcb["state"] = TCP_CLOSE_WAIT
            return
        if len(p["data"]) > 0:
            if p["seq"] == tcb["rcv_nxt"]:
                let i = 0
                while i < len(p["data"]):
                    push(tcb["recv_buf"], p["data"][i])
                    i = i + 1
                tcb["rcv_nxt"] = seq_add(tcb["rcv_nxt"], len(p["data"]))
                tcp_send_ack(tcb)
            else:
                tcp_send_ack(tcb)
            return
        if (flags & TCP_ACK):
            tcb["snd_una"] = p["ack"]
            return
    elif tcb["state"] == TCP_FIN_WAIT1:
        if (flags & TCP_ACK): tcb["state"] = TCP_FIN_WAIT2
        if (flags & TCP_FIN):
            tcb["rcv_nxt"] = seq_add(p["seq"], 1)
            tcp_send_ack(tcb)
            tcb["state"] = TCP_TIME_WAIT
    elif tcb["state"] == TCP_LAST_ACK:
        if (flags & TCP_ACK): tcb["state"] = TCP_CLOSED

proc tcp_poll(fd):
    let tcb = tcp_sockets[fd]
    if tcb == nil: return
    while true:
        let frame = net_rx()
        if frame == nil: break
        let eth = eth_parse(frame)
        if eth["type"] != ETH_TYPE_IPV4 and eth["type"] != ETH_TYPE_ARP: continue
        if eth["type"] == ETH_TYPE_ARP:
            arp_reply_for(eth)
            if tcb["state"] == TCP_SYN_SENT and tcb["pending_syn"]:
                let mac = arp_lookup(tcb["remote_ip"])
                if mac != nil:
                    tcb["remote_mac"] = mac
                    tcb["pending_syn"] = false
                    tcb["snd_una"] = tcb["iss"]
                    tcb["snd_nxt"] = seq_add(tcb["iss"], 1)
                    let seg = tcp_finalize(net_our_ip, tcb["remote_ip"],
                        tcb["local_port"], tcb["remote_port"], tcb["iss"], 0,
                        TCP_SYN, tcb["window"], [])
                    tcb["last_seg"] = seg
                    tcb["retransmit_at"] = net_now_ms() + 1000
                    net_tx(seg)
            continue
        let ip = ipv4_parse(eth["payload"])
        if ip["proto"] != IP_PROTO_TCP: continue
        let seg = ip["payload"]
        let p = tcp_parse(seg)
        net_dbg("poll: state=")
        net_dbg(tcp_state_name(fd))
        net_dbg(" dport=")
        net_dbg(p["dport"])
        net_dbg(" expect=")
        net_dbg(tcb["local_port"])
        net_dbg(" sport=")
        net_dbg(p["sport"])
        net_dbg(" flags=")
        net_dbg(p["flags"])
        if p["dport"] != tcb["local_port"]: continue
        if tcb["remote_ip"] != 0 and ip["src"] != tcb["remote_ip"]: continue
        if tcb["remote_port"] != 0 and p["sport"] != tcb["remote_port"]: continue
        tcp_input(tcb, seg)
    if tcb["retransmit_at"] != 0 and net_now_ms() >= tcb["retransmit_at"]:
        if (tcb["state"] == TCP_SYN_SENT or tcb["state"] == TCP_ESTABLISHED) and tcb["last_seg"] != nil:
            net_tx(tcb["last_seg"])
            tcb["retransmit_at"] = net_now_ms() + 2000

proc tcp_write(fd, data):
    let tcb = tcp_sockets[fd]
    if tcb == nil or tcb["state"] != TCP_ESTABLISHED: return -1
    let seg = tcp_finalize(net_our_ip, tcb["remote_ip"], tcb["local_port"],
                           tcb["remote_port"], tcb["snd_nxt"], tcb["rcv_nxt"],
                           TCP_PSH | TCP_ACK, tcb["window"], data)
    tcb["last_seg"] = seg
    tcb["snd_nxt"] = seq_add(tcb["snd_nxt"], len(data))
    tcb["retransmit_at"] = net_now_ms() + 1000
    net_tx(seg)
    return len(data)

proc tcp_read(fd):
    let tcb = tcp_sockets[fd]
    if tcb == nil: return nil
    if len(tcb["recv_buf"]) == 0: return nil
    let data = tcb["recv_buf"]
    tcb["recv_buf"] = []
    return data

proc tcp_close(fd):
    let tcb = tcp_sockets[fd]
    if tcb == nil: return
    if tcb["state"] == TCP_ESTABLISHED:
        let seg = tcp_finalize(net_our_ip, tcb["remote_ip"], tcb["local_port"],
                               tcb["remote_port"], tcb["snd_nxt"], tcb["rcv_nxt"],
                               TCP_FIN | TCP_ACK, tcb["window"], [])
        tcb["last_seg"] = seg
        tcb["state"] = TCP_FIN_WAIT1
        tcb["retransmit_at"] = net_now_ms() + 1000
        net_tx(seg)
    elif tcb["state"] == TCP_CLOSE_WAIT:
        let seg = tcp_finalize(net_our_ip, tcb["remote_ip"], tcb["local_port"],
                               tcb["remote_port"], tcb["snd_nxt"], tcb["rcv_nxt"],
                               TCP_FIN | TCP_ACK, tcb["window"], [])
        tcb["last_seg"] = seg
        tcb["state"] = TCP_LAST_ACK
        tcb["retransmit_at"] = net_now_ms() + 1000
        net_tx(seg)

proc tcp_state_name(fd):
    let tcb = tcp_sockets[fd]
    if tcb == nil: return "INVALID"
    let st = tcb["state"]
    if st >= 0 and st < len(TCP_STATE_NAMES):
        return TCP_STATE_NAMES[st]
    return "?"

proc tcp_is_established(fd):
    let tcb = tcp_sockets[fd]
    if tcb == nil: return false
    return tcb["state"] == TCP_ESTABLISHED
