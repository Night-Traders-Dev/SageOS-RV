# Network Stack — Architecture

SageOS-RV includes a full pure-Sage TCP/IP network stack in `kernel/net/`.

---

## Protocol Layers

```mermaid
flowchart TB
    L1["<b>HTTP (RFC 7230)</b> — GET/POST client"]
    L2["<b>TLS 1.3 (RFC 8446)</b> — encryption<br/><i>AES-128-GCM, ClientHello handshake</i>"]
    L3["<b>TCP (RFC 793)</b> — reliable transport<br/><i>11-state FSM, 3-way handshake</i>"]
    L4["<b>UDP (RFC 768)</b> — datagram transport"]
    L5["<b>DNS (RFC 1035)</b> — name resolution<br/><b>DHCP (RFC 2131)</b> — IP configuration"]
    L6["<b>IPv4 (RFC 791)</b> — network layer<br/><i>Checksums, fragmentation, routing</i>"]
    L7["<b>Ethernet (IEEE 802.3)</b> — MAC layer<br/><i>14-byte frames, EtherType dispatch</i>"]
    L8["<b>WiFi Driver (AIC8800D)</b><br/><i>SDIO transport, firmware loading</i>"]
    
    L1 --- L2 --- L3 --- L4 --- L5 --- L6 --- L7 --- L8
    
    style L1 fill:#0984e3,color:#fff
    style L2 fill:#0984e3,color:#fff
    style L3 fill:#0984e3,color:#fff
    style L4 fill:#00b894,color:#fff
    style L5 fill:#00b894,color:#fff
    style L6 fill:#fdcb6e,color:#000
    style L7 fill:#e17055,color:#fff
    style L8 fill:#d63031,color:#fff
```

## Data Flow

```mermaid
flowchart LR
    subgraph TX["Transmit (TX)"]
        direction LR
        T1[App] --> T2[HTTP] --> T3[TLS encrypt] --> T4[TCP segment] --> T5[IP packet] --> T6[ETH frame] --> T7[WiFi]
    end
    
    subgraph RX["Receive (RX)"]
        direction LR
        R1[WiFi] --> R2[ETH parse] --> R3[IP parse] --> R4[TCP reassemble] --> R5[TLS decrypt] --> R6[HTTP] --> R7[App]
    end
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

```mermaid
stateDiagram-v2
    [*] --> CLOSED
    CLOSED --> LISTEN : passive OPEN\n(create TCB)
    CLOSED --> SYN_SENT : active OPEN\n(create TCB, snd SYN)
    
    LISTEN --> SYN_RCVD : rcv SYN\n(snd SYN,ACK)
    LISTEN --> CLOSED : CLOSE\n(delete TCB)
    LISTEN --> SYN_SENT : SEND\n(snd SYN)
    
    SYN_RCVD --> ESTABLISHED : rcv ACK of SYN
    SYN_RCVD --> LISTEN : rcv RST
    SYN_RCVD --> FIN_WAIT_1 : CLOSE\n(snd FIN)
    
    SYN_SENT --> SYN_RCVD : rcv SYN\n(snd SYN,ACK)
    SYN_SENT --> ESTABLISHED : rcv SYN,ACK\n(snd ACK)
    SYN_SENT --> CLOSED : CLOSE\n(delete TCB)
    
    ESTABLISHED --> FIN_WAIT_1 : CLOSE\n(snd FIN)
    ESTABLISHED --> CLOSE_WAIT : rcv FIN\n(snd ACK)
    
    FIN_WAIT_1 --> FIN_WAIT_2 : rcv ACK of FIN
    FIN_WAIT_1 --> CLOSING : rcv FIN\n(snd ACK)
    FIN_WAIT_1 --> TIME_WAIT : rcv FIN,ACK\n(snd ACK)
    
    FIN_WAIT_2 --> TIME_WAIT : rcv FIN\n(snd ACK)
    
    CLOSE_WAIT --> LAST_ACK : CLOSE\n(snd FIN)
    
    CLOSING --> TIME_WAIT : rcv ACK of FIN
    
    LAST_ACK --> CLOSED : rcv ACK of FIN\n(delete TCB)
    
    TIME_WAIT --> CLOSED : Timeout=2MSL\n(delete TCB)
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
