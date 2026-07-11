## tests/tcp_test_driver.sage — TCP/IP stack unit test (host `sage`)
##
## Concatenated AFTER kernel/net/tcp_stack.sage and run with the host
## `sage` interpreter.  NOTE: Sage resolves free variables at compile time,
## so all module-level state must be declared BEFORE the procs that use it.
##
## Uses the loopback transport backend plus a small in-software peer (a
## minimal TCP server) that answers SYN with SYN-ACK, echoes payloads, and
## answers FIN.

## --- environment / module state (declared before procs) ---
let net_backend   = "loopback"
let net_our_mac   = [0x52, 0x55, 0x0A, 0x00, 0x00, 0x01]
let net_our_ip    = ip_aton("10.0.2.15")

let peer_mac      = [0x52, 0x55, 0x0A, 0x00, 0x00, 0x02]
let peer_ip       = ip_aton("10.0.2.2")
let peer_port     = 22
let peer_iss      = 0x2000
let peer_snd_nxt  = 0
let peer_rcv_nxt  = 0

let g_fail = 0
let g_pass = 0

## --- test harness ---
proc assert(cond, msg):
    if cond:
        print("[PASS] ")
        print(msg)
        g_pass = g_pass + 1
    else:
        print("[FAIL] ")
        print(msg)
        g_fail = g_fail + 1

## --- software peer (minimal TCP server) ---

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
    let out = eth_build(dsts, peer_mac, ETH_TYPE_IPV4, ipp)
    push(loop_rx_q, out)

proc peer_tick():
    let guard = 0
    while len(loop_tx_q) > 0 and guard < 64:
        guard = guard + 1
        let frame = peer_pop_tx()
        if frame == nil: break
        let eth = eth_parse(frame)
        if eth["type"] == ETH_TYPE_ARP:
            let p = eth["payload"]
            if get_u16(p, 6) == ARP_OP_REQUEST and get_u32(p, 24) == peer_ip:
                let sha = [p[8], p[9], p[10], p[11], p[12], p[13]]
                let spa = get_u32(p, 14)
                let reply = arp_build(ARP_OP_REPLY, peer_mac, peer_ip, sha, spa)
                let out = eth_build(sha, peer_mac, ETH_TYPE_ARP, reply)
                push(loop_rx_q, out)
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
            peer_send_tcp(eth["src"], ip["src"], peer_port, our_sport,
                          peer_snd_nxt, peer_rcv_nxt, TCP_PSH | TCP_ACK, p["data"])
            peer_snd_nxt = seq_add(peer_snd_nxt, len(p["data"]))

## --- Test 1: IPv4 header checksum self-consistency + RFC vector ---
proc t_ipv4_cksum():
    let h = []
    push(h, 0x45)
    push(h, 0x00)
    put_u16(h, 0x0030)
    put_u16(h, 0x1c46)
    put_u16(h, 0x4000)
    push(h, 0x40)
    push(h, 0x06)
    put_u16(h, 0)
    put_u32(h, ip_aton("192.168.0.2"))
    put_u32(h, ip_aton("192.168.0.1"))
    let c = ipv4_checksum(h)
    h[10] = (c >> 8) & 0xFF
    h[11] = c & 0xFF
    ## A correctly checksummed header recomputes to 0x0000.
    assert(ipv4_checksum(h) == 0, "IPv4 checksum self-checks to 0x0000")
    ## RFC 1071 Appendix 4.1 known vector (header with zeroed checksum field)
    let v = [0x45,0x00,0x00,0x30,0x44,0x22,0x40,0x00,0x80,0x06,0x00,0x00,
             0xAC,0x10,0x0A,0x63,0xAC,0x10,0x0A,0x0C]
    assert(ipv4_checksum(v) == 0x4A16, "IPv4 checksum matches RFC 1071 vector (0x4A16)")

## --- Test 2: TCP checksum self-consistency ---
proc t_tcp_cksum():
    let seg = tcp_build(1234, 22, 0x1000, 0, TCP_SYN, 65535, [])
    let c = tcp_checksum(ip_aton("10.0.2.15"), ip_aton("10.0.2.2"), seg)
    seg[16] = (c >> 8) & 0xFF
    seg[17] = c & 0xFF
    let c2 = tcp_checksum(ip_aton("10.0.2.15"), ip_aton("10.0.2.2"), seg)
    assert(c2 == 0, "TCP checksum self-checks to 0x0000")

## --- Test 3: ARP request / reply ---
proc t_arp():
    arp_table = []
    assert(arp_lookup(peer_ip) == nil, "ARP cache empty before request")
    arp_request(peer_ip)
    peer_tick()
    let fd = tcp_socket()      ## drain the queued ARP reply through the stack
    tcp_poll(fd)
    let mac = arp_lookup(peer_ip)
    assert(not (mac == nil), "ARP reply populated cache")
    if not (mac == nil):
        assert(mac_eq(mac, peer_mac), "ARP resolved correct MAC")

## --- Test 4: full 3-way handshake ---
proc t_handshake():
    arp_table = []
    arp_add(peer_ip, peer_mac)
    let fd = tcp_socket()
    tcp_connect(fd, peer_ip, peer_port)
    assert(tcp_state_name(fd) == "SYN_SENT", "state SYN_SENT after connect")
    peer_tick()
    tcp_poll(fd)
    peer_tick()
    assert(tcp_is_established(fd), "connection ESTABLISHED after handshake")
    assert(tcp_state_name(fd) == "ESTABLISHED", "state ESTABLISHED")

## --- Test 5: data exchange (echo) ---
proc t_echo():
    arp_add(peer_ip, peer_mac)
    let fd = tcp_socket()
    tcp_connect(fd, peer_ip, peer_port)
    peer_tick()
    tcp_poll(fd)
    peer_tick()
    assert(tcp_is_established(fd), "established before data")
    let msg = [0x68, 0x65, 0x6C, 0x6C, 0x6F]
    tcp_write(fd, msg)
    peer_tick()
    tcp_poll(fd)
    let got = tcp_read(fd)
    assert(not (got == nil), "received echoed data")
    if not (got == nil):
        assert(len(got) == 5 and got[0] == 0x68 and got[4] == 0x6F,
               "echoed payload matches 'hello'")

## --- Test 6: graceful close ---
proc t_close():
    arp_add(peer_ip, peer_mac)
    let fd = tcp_socket()
    tcp_connect(fd, peer_ip, peer_port)
    peer_tick()
    tcp_poll(fd)
    peer_tick()
    assert(tcp_is_established(fd), "established before close")
    tcp_close(fd)
    assert(tcp_state_name(fd) == "FIN_WAIT1", "state FIN_WAIT1 after close")
    peer_tick()
    tcp_poll(fd)
    assert(tcp_state_name(fd) == "TIME_WAIT", "state TIME_WAIT after peer FIN")

## --- run ---
print("=== TCP/IP stack unit tests ===\n")
t_ipv4_cksum()
t_tcp_cksum()
t_arp()
t_handshake()
t_echo()
t_close()
print("\n")
print("PASS=")
print(g_pass)
print(" FAIL=")
print(g_fail)
print("\n")
if g_fail == 0:
    print("RESULT: ALL TESTS PASSED\n")
else:
    print("RESULT: FAILURES PRESENT\n")
