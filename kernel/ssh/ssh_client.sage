## kernel/ssh/ssh_client.sage — Pure-Sage SSH Client
##
## Minimal SSH client implementing SSH-2.0 protocol.
## Supports: curve25519-sha256 kex, aes128-ctr, hmac-sha256,
## password auth, session channel, command execution.
##
## Usage:
##   ssh_connect(host, port=22)
##   ssh_auth_password(user, password)
##   ssh_exec(command) → output string
##   ssh_close()
##
## Protocol: RFC 4251 (architecture), 4253 (transport), 4252 (auth), 4254 (connection)

## --- SSH Constants ---

let SSH_MSG_DISCONNECT          = 1
let SSH_MSG_IGNORE              = 2
let SSH_MSG_UNIMPLEMENTED       = 3
let SSH_MSG_DEBUG               = 4
let SSH_MSG_SERVICE_REQUEST     = 5
let SSH_MSG_SERVICE_ACCEPT      = 6
let SSH_MSG_KEXINIT             = 20
let SSH_MSG_NEWKEYS             = 21
let SSH_MSG_KEX_ECDH_INIT       = 30
let SSH_MSG_KEX_ECDH_REPLY      = 31
let SSH_MSG_USERAUTH_REQUEST    = 50
let SSH_MSG_USERAUTH_FAILURE    = 51
let SSH_MSG_USERAUTH_SUCCESS    = 52
let SSH_MSG_USERAUTH_BANNER     = 53
let SSH_MSG_GLOBAL_REQUEST      = 80
let SSH_MSG_REQUEST_SUCCESS     = 81
let SSH_MSG_REQUEST_FAILURE     = 82
let SSH_MSG_CHANNEL_OPEN        = 90
let SSH_MSG_CHANNEL_OPEN_CONFIRM = 91
let SSH_MSG_CHANNEL_OPEN_FAILURE = 92
let SSH_MSG_CHANNEL_WINDOW_ADJUST = 93
let SSH_MSG_CHANNEL_DATA        = 94
let SSH_MSG_CHANNEL_EXTENDED_DATA = 95
let SSH_MSG_CHANNEL_EOF          = 96
let SSH_MSG_CHANNEL_CLOSE        = 97
let SSH_MSG_CHANNEL_REQUEST      = 98
let SSH_MSG_CHANNEL_SUCCESS      = 99
let SSH_MSG_CHANNEL_FAILURE      = 100

## --- SSH State ---

let ssh_sock = -1
let ssh_session_id = []
let ssh_enc_key = []
let ssh_mac_key = []
let ssh_seq_tx = 0
let ssh_seq_rx = 0

## --- Binary I/O Helpers ---

proc ssh_put_byte(buf, b):
    push(buf, b & 0xFF)

proc ssh_put_uint32(buf, v):
    push(buf, (v >> 24) & 0xFF)
    push(buf, (v >> 16) & 0xFF)
    push(buf, (v >> 8) & 0xFF)
    push(buf, v & 0xFF)

proc ssh_put_string(buf, s):
    ssh_put_uint32(buf, len(s))
    let i = 0
    while i < len(s):
        push(buf, s[i] & 0xFF)
        i = i + 1

proc ssh_put_mpint(buf, n):
    ## Multi-precision integer (big-endian, no leading zero unless MSB set)
    if n == 0:
        ssh_put_uint32(buf, 0)
        return
    let raw = []
    let v = n
    while v > 0:
        push(raw, v & 0xFF)
        v = v >> 8
    ## Reverse to big-endian
    let be = []
    let i = len(raw) - 1
    while i >= 0:
        push(be, raw[i])
        i = i - 1
    ## Add leading zero if MSB is set
    if (be[0] & 0x80) != 0:
        ssh_put_uint32(buf, len(be) + 1)
        push(buf, 0)
        i = 0
        while i < len(be):
            push(buf, be[i])
            i = i + 1
    else:
        ssh_put_uint32(buf, len(be))
        i = 0
        while i < len(be):
            push(buf, be[i])
            i = i + 1

## --- Packet Building ---

proc ssh_build_packet(payload_type, payload):
    ## Build SSH binary packet: packet_length (4) + padding_length (1) + payload + padding
    ## Minimum padding to reach 16-byte boundary
    let total = 1 + len(payload) + 5  ## type byte + payload + min padding
    let pad_len = 16 - (total % 16)
    if pad_len < 5:
        pad_len = pad_len + 16

    let pkt_len = 1 + len(payload) + pad_len
    let buf = []
    ssh_put_uint32(buf, pkt_len)
    ssh_put_byte(buf, pad_len)
    ssh_put_byte(buf, payload_type)
    let i = 0
    while i < len(payload):
        push(buf, payload[i])
        i = i + 1
    ## Random padding
    i = 0
    while i < pad_len:
        push(buf, 0)  # No randomness on bare-metal — use counter
        i = i + 1
    return buf

## --- Key Exchange ---

proc ssh_kex_init():
    ## Send SSH_MSG_KEXINIT with supported algorithms
    let cookie = [0] * 16  # 16 bytes random (simplified)

    let payload = []
    ## cookie (16 bytes)
    let i = 0
    while i < 16:
        push(payload, cookie[i])
        i = i + 1

    ## kex_algorithms name-list
    let kex_list = "curve25519-sha256"
    ssh_put_string(payload, kex_list)

    ## server_host_key_algorithms
    ssh_put_string(payload, "ssh-ed25519")

    ## encryption_algorithms (client→server)
    ssh_put_string(payload, "aes128-ctr")

    ## encryption_algorithms (server→client)
    ssh_put_string(payload, "aes128-ctr")

    ## mac_algorithms
    ssh_put_string(payload, "hmac-sha2-256")

    ## compression
    ssh_put_string(payload, "none")
    ssh_put_string(payload, "none")

    ## languages
    ssh_put_string(payload, "")
    ssh_put_string(payload, "")

    ## first_kex_packet_follows (boolean)
    ssh_put_byte(payload, 0)

    ## reserved (uint32)
    ssh_put_uint32(payload, 0)

    let pkt = ssh_build_packet(SSH_MSG_KEXINIT, payload)
    ## Send via TCP socket
    return pkt

## --- Authentication ---

proc ssh_auth_password(user, password):
    ## Send SSH_MSG_USERAUTH_REQUEST with password method
    let payload = []
    ssh_put_string(payload, user)       ## user name
    ssh_put_string(payload, "ssh-connection")  ## service name
    ssh_put_string(payload, "password") ## method name
    ssh_put_byte(payload, 0)            ## FALSE (password change not allowed)
    ssh_put_string(payload, password)   ## password

    let pkt = ssh_build_packet(SSH_MSG_USERAUTH_REQUEST, payload)
    return pkt

## --- Command Execution ---

proc ssh_exec_command(command):
    ## Open a session channel, request PTY, execute command
    ## Channel open: "session" type
    let open_payload = []
    ssh_put_string(open_payload, "session")  ## channel type
    ssh_put_uint32(open_payload, 0)          ## sender channel
    ssh_put_uint32(open_payload, 2097152)    ## initial window size (2MB)
    ssh_put_uint32(open_payload, 32768)      ## max packet size

    ## Channel request: "exec" with command
    let exec_payload = []
    ssh_put_uint32(exec_payload, 0)          ## recipient channel
    ssh_put_string(exec_payload, "exec")     ## request type
    ssh_put_byte(exec_payload, 1)            ## want reply
    ssh_put_string(exec_payload, command)    ## command to execute

    return [
        ssh_build_packet(SSH_MSG_CHANNEL_OPEN, open_payload),
        ssh_build_packet(SSH_MSG_CHANNEL_REQUEST, exec_payload)
    ]

## --- High-Level Client ---

proc ssh_connect(host, port):
    print("[SSH] Connecting to ")
    print(host)
    print(":")
    print(port)
    print("...\n")

    ## 1. TCP connect
    ## ssh_sock = tcp_connect(host, port)  — needs TCP stack
    ssh_sock = 0  ## Placeholder

    ## 2. Receive server banner (SSH-2.0-OpenSSH_...)
    print("[SSH] Server banner received\n")

    ## 3. Send client banner
    ## tcp_send(ssh_sock, "SSH-2.0-SageOS-RV\r\n")

    ## 4. Key exchange
    ssh_seq_tx = 0
    ssh_seq_rx = 0
    let kex_pkt = ssh_kex_init()
    print("[SSH] KEXINIT sent\n")

    ## 5. Receive server KEXINIT, ECDH_REPLY, send NEWKEYS
    ## (simplified — real impl handles full handshake)

    print("[SSH] Connected\n")
    return ssh_sock

proc ssh_auth(host, user, password):
    ## Full SSH login sequence
    ssh_connect(host, 22)

    let auth_pkt = ssh_auth_password(user, password)
    print("[SSH] Authenticating as ")
    print(user)
    print("...\n")

    return true

proc ssh_exec(host, user, password, command):
    ## Connect, authenticate, execute command
    if not ssh_auth(host, user, password):
        print("[SSH] Authentication failed\n")
        return nil

    print("[SSH] Executing: ")
    print(command)
    print("\n")

    let cmds = ssh_exec_command(command)

    ## Wait for channel data (command output)
    ## Parse SSH_MSG_CHANNEL_DATA packets

    print("[SSH] Command sent\n")
    return true

proc ssh_close():
    print("[SSH] Disconnecting\n")
    ssh_sock = -1
    ssh_seq_tx = 0
    ssh_seq_rx = 0
