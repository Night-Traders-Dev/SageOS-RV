## kernel/net/tcp.sage — TCP Transport Layer (RFC 793/9293)
##
## Reliable, ordered, connection-oriented byte stream.
## Three-way handshake, data transfer, graceful close.
## State machine: CLOSED→LISTEN→SYN_RCVD→ESTABLISHED→FIN_WAIT→CLOSED

let TCP_HDR_MIN = 20

## Flags
let TCP_FIN = 0x01
let TCP_SYN = 0x02
let TCP_RST = 0x04
let TCP_PSH = 0x08
let TCP_ACK = 0x10
let TCP_URG = 0x20

## States
let TCP_CLOSED      = 0
let TCP_LISTEN      = 1
let TCP_SYN_SENT    = 2
let TCP_SYN_RCVD    = 3
let TCP_ESTABLISHED = 4
let TCP_FIN_WAIT1   = 5
let TCP_FIN_WAIT2   = 6
let TCP_CLOSING     = 7
let TCP_TIME_WAIT   = 8
let TCP_CLOSE_WAIT  = 9
let TCP_LAST_ACK    = 10

let tcp_sockets = []
let tcp_seed = 0x12345678

proc tcp_checksum(src_ip, dst_ip, tcp_hdr, payload):
    ## Pseudo-header + TCP header + payload checksum
    return 0  ## stub — requires actual 16-bit sum

proc tcp_build(src_port, dst_port, seq, ack, flags, window, payload):
    ## Build TCP segment with header + options + payload
    let seg = []
    tcp_put_u16(seg, src_port)     ## Source port
    tcp_put_u16(seg, dst_port)     ## Dest port
    tcp_put_u32(seg, seq)          ## Sequence number
    tcp_put_u32(seg, ack)          ## ACK number
    tcp_put_byte(seg, 0x50)        ## Data offset (5 words) + reserved
    tcp_put_byte(seg, flags)       ## Flags
    tcp_put_u16(seg, window)       ## Window size
    tcp_put_u16(seg, 0)            ## Checksum placeholder
    tcp_put_u16(seg, 0)            ## Urgent pointer
    tcp_append(seg, payload)
    return seg

proc tcp_create_tcb(local_port):
    ## Create Transmission Control Block
    tcp_seed = (tcp_seed * 1103515245 + 12345) & 0xFFFFFFFF
    let isn = tcp_seed
    return {
        state:       TCP_CLOSED,
        local_port:  local_port,
        remote_port: 0,
        remote_ip:   0,
        snd_una:     isn,  ## oldest unacknowledged seq
        snd_nxt:     isn,  ## next seq to send
        rcv_nxt:     0,    ## next expected seq
        snd_wnd:     65535,
        rcv_wnd:     65535,
        send_buf:    [],
        recv_buf:    [],
        retransmit:  0
    }

proc tcp_connect(tcb, dst_ip, dst_port):
    ## Active open: send SYN
    tcb.state = TCP_SYN_SENT
    tcb.remote_ip = dst_ip
    tcb.remote_port = dst_port
    let syn_seg = tcp_build(tcb.local_port, dst_port,
        tcb.snd_nxt, 0, TCP_SYN, tcb.rcv_wnd, [])
    tcb.snd_nxt = tcb.snd_nxt + 1  ## SYN consumes 1 seq
    return syn_seg

proc tcp_listen(port):
    let tcb = tcp_create_tcb(port)
    tcb.state = TCP_LISTEN
    push(tcp_sockets, tcb)
    return len(tcp_sockets) - 1

proc tcp_process(seg, src_ip, dst_ip):
    ## Process incoming TCP segment, update state machine
    let flags = seg[13]
    let seq  = (seg[4]<<24)|(seg[5]<<16)|(seg[6]<<8)|seg[7]
    let ack  = (seg[8]<<24)|(seg[9]<<16)|(seg[10]<<8)|seg[11]
    let src  = (seg[0]<<8)|seg[1]
    let dst  = (seg[2]<<8)|seg[3]

    ## Find matching socket
    let i = 0
    while i < len(tcp_sockets):
        let tcb = tcp_sockets[i]
        if tcb != nil and tcb.local_port == dst:
            ## State machine transitions
            if tcb.state == TCP_LISTEN and (flags & TCP_SYN):
                ## Passive open
                tcb.rcv_nxt = seq + 1
                tcb.state = TCP_SYN_RCVD
                ## Send SYN-ACK
            elif tcb.state == TCP_SYN_SENT:
                if (flags & TCP_SYN) and (flags & TCP_ACK):
                    tcb.rcv_nxt = seq + 1
                    tcb.snd_una = ack
                    tcb.state = TCP_ESTABLISHED
                elif (flags & TCP_SYN):
                    ## Simultaneous open
                    tcb.rcv_nxt = seq + 1
                    tcb.state = TCP_SYN_RCVD
            elif tcb.state == TCP_ESTABLISHED:
                if (flags & TCP_FIN):
                    tcb.state = TCP_CLOSE_WAIT
                    tcb.rcv_nxt = seq + 1
                elif len(seg) > 20:  ## Data segment
                    let data = seg[20:]
                    tcp_append_data(tcb, data)
                    tcb.rcv_nxt = seq + len(data)
            elif tcb.state == TCP_FIN_WAIT1:
                if (flags & TCP_ACK): tcb.state = TCP_FIN_WAIT2
                if (flags & TCP_FIN): tcb.state = TCP_TIME_WAIT
            elif tcb.state == TCP_LAST_ACK:
                if (flags & TCP_ACK): tcb.state = TCP_CLOSED
            return tcb
        i = i + 1
    return nil

proc tcp_close(tcb):
    ## Active close: send FIN
    tcb.state = TCP_FIN_WAIT1
    let fin_seg = tcp_build(tcb.local_port, tcb.remote_port,
        tcb.snd_nxt, tcb.rcv_nxt, TCP_FIN | TCP_ACK, tcb.rcv_wnd, [])
    tcb.snd_nxt = tcb.snd_nxt + 1
    return fin_seg

proc tcp_send(tcb, data):
    if tcb.state != TCP_ESTABLISHED: return nil
    let seg = tcp_build(tcb.local_port, tcb.remote_port,
        tcb.snd_nxt, tcb.rcv_nxt, TCP_PSH | TCP_ACK, tcb.rcv_wnd, data)
    tcb.snd_nxt = tcb.snd_nxt + len(data)
    return seg

proc tcp_recv(tcb):
    if len(tcb.recv_buf) == 0: return nil
    let data = tcb.recv_buf[0]
    ## Would shift queue — simplified: just return first
    return data

proc tcp_append_data(tcb, data):
    let i = 0; while i < len(data): push(tcb.recv_buf, data[i]); i = i + 1

proc tcp_put_u16(buf, v): push(buf,(v>>8)&0xFF); push(buf,v&0xFF)
proc tcp_put_u32(buf, v):
    push(buf,(v>>24)&0xFF); push(buf,(v>>16)&0xFF)
    push(buf,(v>>8)&0xFF); push(buf,v&0xFF)
proc tcp_put_byte(buf, b): push(buf, b & 0xFF)
proc tcp_append(buf, data): tcp_append_data(buf, data)  ## reuse impl
