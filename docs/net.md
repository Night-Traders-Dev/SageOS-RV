# Network Stack — Architecture

SageOS-RV includes a full pure-Sage TCP/IP network stack in `kernel/net/`.

---

## Protocol Layers

```
┌─────────────────────────────────────┐
│  HTTP (RFC 7230) — GET/POST client  │
├─────────────────────────────────────┤
│  TLS 1.3 (RFC 8446) — encryption   │
│  AES-128-GCM, ClientHello handshake │
├─────────────────────────────────────┤
│  TCP (RFC 793) — reliable transport │
│  11-state FSM, 3-way handshake      │
├─────────────────────────────────────┤
│  UDP (RFC 768) — datagram transport │
├─────────────────────────────────────┤
│  DNS (RFC 1035) — name resolution   │
│  DHCP (RFC 2131) — IP configuration │
├─────────────────────────────────────┤
│  IPv4 (RFC 791) — network layer     │
│  Checksums, fragmentation, routing  │
├─────────────────────────────────────┤
│  Ethernet (IEEE 802.3) — MAC layer  │
│  14-byte frames, EtherType dispatch │
├─────────────────────────────────────┤
│  WiFi Driver (AIC8800D)             │
│  SDIO transport, firmware loading   │
└─────────────────────────────────────┘
```

## Data Flow

```
TX: App → HTTP → TLS encrypt → TCP segment → IP packet → ETH frame → WiFi
RX: WiFi → ETH parse → IP parse → TCP reassemble → TLS decrypt → HTTP → App
```

## WiFi Integration

The full pipeline is wired:

```sage
# 1. Connect WiFi
a = aic_wifi_connect("MyWiFi", "password")

# 2. Get IP via DHCP
dhcp_discover()
ip = dhcp_get_ip()           # 192.168.1.100

# 3. Resolve DNS
answers = dns_resolve("example.com", "8.8.8.8")

# 4. HTTP GET
req = http_request("GET", "example.com", "/")
# Pipeline: http → tls_encrypt → tcp_build → ip_build → eth_build
```

## Protocol Files

| File | Lines | Protocol | Key Features |
|---|---|---|---|
| `ethernet.sage` | 50 | IEEE 802.3 | Frame build/parse, EtherType, broadcast |
| `ipv4.sage` | 60 | RFC 791 | Checksum, fragmentation, TTL, routing |
| `tcp.sage` | 150 | RFC 793 | 11-state FSM, 3-way handshake, TCB, graceful close |
| `udp.sage` | 20 | RFC 768 | Datagram build/parse, port numbers |
| `dns.sage` | 65 | RFC 1035 | A record query, name encoding, reply parse |
| `dhcp.sage` | 50 | RFC 2131 | DORA cycle, IP/mask/gw/DNS extraction |
| `http.sage` | 70 | RFC 7230 | GET/POST, header parsing, status codes |
| `tls.sage` | 60 | RFC 8446 | ClientHello, cipher suite negotiation, AES-128-GCM |
| `wifi_net.sage` | 40 | — | WiFi→Net bridge, scan→connect→DHCP→IP |
| `stack.sage` | 120 | — | Full TCP/IP stack integration |

## TCP State Machine

```
                         +---------+ ---------\      active OPEN
                         |  CLOSED |            \    -----------
                         +---------+<---------\   \   create TCB
                           |     ^              \   \  snd SYN
              passive OPEN |     |   CLOSE        \   \
              ------------ |     | ----------       \   \
               create TCB  |     | delete TCB         \   \
                           V     |                      \   \
                         +---------+            CLOSE    |    \
                         |  LISTEN |          ---------- |     |
                         +---------+          delete TCB |     |
              rcv SYN      |     |     SEND              |     |
             -----------   |     |    -------            |     V
+---------+ snd SYN,ACK  /       \   snd SYN          +---------+
|         |<-----------------           ------------------|         |
|   SYN   |                    rcv SYN                     |   SYN   |
|   RCVD  |<-----------------------------------------------|   SENT  |
|         |                    snd ACK                     |         |
|         |------------------           -------------------|         |
+---------+   rcv ACK of SYN  \       /  rcv SYN,ACK       +---------+
  |           --------------   |     |   -------------
  |                  x         |     |     snd ACK
  |                            V     V
  |  CLOSE                   +---------+
  | -------                  |  ESTAB  |
  | snd FIN                  +---------+
  |                   CLOSE    |     |    rcv FIN
  V                  -------   |     |    -------
+---------+          snd FIN  /       \   snd ACK          +---------+
|  FIN    |<-----------------           ------------------>|  CLOSE  |
| WAIT-1  |------------------                              |   WAIT  |
+---------+          rcv FIN  \                            +---------+
  | rcv ACK of FIN   -------   |                            CLOSE  |
  | --------------   snd ACK   |                           ------- |
  V        x                   V                           snd FIN V
+---------+                  +---------+                   +---------+
|FINWAIT-2|                  | CLOSING |                   | LAST-ACK|
+---------+                  +---------+                   +---------+
  |                rcv ACK of FIN |                 rcv ACK of FIN |
  |                -------------- |                 -------------- |
  |   Timeout=2MSL -------------- |                   x    delete TCB
  V              \               V                            V
+---------+       \         +---------+                  +---------+
|  TIME   |        -------->|  CLOSED |                  |  CLOSED |
|  WAIT   |                 +---------+                  +---------+
+---------+
```

## Test Suite

```bash
python3 tests/net_test.py
# 64/64 tests pass — validates all protocol constants, checksums, state machines
```

Output validates against:
- IEEE 802.3 frame format
- RFC 791 IPv4 header + checksum computation
- RFC 793 TCP 11-state machine + flag bits
- RFC 768 UDP datagram format
- RFC 1035 DNS query structure
- RFC 2131 DHCP message types + DORA cycle
- RFC 7230 HTTP/1.1 request format
- RFC 8446 TLS 1.3 handshake + cipher suite
