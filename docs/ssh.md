# SSH Client & Cluster Monitor

SageOS-RV includes a pure-Sage SSH-2.0 client for remote cluster management.

---

## Architecture

```
┌─────────────────────────────────────────┐
│  cluster_monitor.sage                   │
│  Multi-node RAM checker + cleanup       │
├─────────────────────────────────────────┤
│  ssh_client.sage                        │
│  SSH-2.0 protocol (RFC 4251-4254)      │
│  KEX, auth, channels, command exec     │
├─────────────────────────────────────────┤
│  kernel/crypto/                         │
│  sha256.sage  hmac.sage                │
│  FIPS 180-4    RFC 2104               │
├─────────────────────────────────────────┤
│  TCP/IP stack (kernel/net/stack.sage)   │
└─────────────────────────────────────────┘
```

---

## SSH Client (`kernel/ssh/ssh_client.sage`)

Implements SSH-2.0 wire protocol:

| Layer | RFC | Features |
|---|---|---|
| Transport | 4253 | Packet framing, encryption, MAC |
| Authentication | 4252 | Password auth |
| Connection | 4254 | Session channels, command exec |

### Supported Algorithms

- Key exchange: `curve25519-sha256`
- Encryption: `aes128-ctr`
- MAC: `hmac-sha2-256`
- Host key: `ssh-ed25519`

### Wire Format

SSH binary packet structure:
```
uint32    packet_length    (not including MAC)
byte      padding_length
byte[n1]  payload          (may be compressed)
byte[n2]  random padding   (min 4 bytes to reach 8-byte boundary)
byte[m]   MAC              (if negotiated)
```

### Usage

```sage
import ssh_client

ssh_client.ssh_connect("192.168.1.101", 22)
ssh_client.ssh_auth_password("sageos", "password")
ssh_client.ssh_exec("free -m")
ssh_client.ssh_close()
```

---

## Crypto Library (`kernel/crypto/`)

### SHA-256 (`sha256.sage`)

FIPS 180-4 compliant implementation:
- 64-round compression function
- Message padding per spec (0x80 + zeros + 64-bit length)
- All 64 round constants
- Verified against NIST test vectors

### HMAC-SHA256 (`hmac.sage`)

RFC 2104 implementation:
- Inner/outer padding (ipad=0x36, opad=0x5C)
- Key handling (hash if > 64 bytes)
- Verified against RFC 4231 test cases

---

## Cluster Monitor (`kernel/ssh/cluster_monitor.sage`)

The LicheeRV Nano's primary cluster role — SSHes into 3 nodes,
checks RAM usage, and runs memory cleanup when below threshold.

### Configuration

```sage
let CLUSTER_NODES = ["192.168.1.101", "192.168.1.102", "192.168.1.103"]
let CLUSTER_USER = "sageos"
let RAM_THRESHOLD = 20    # Run cleanup when below 20% RAM
let MONITOR_INTERVAL = 60 # Check every 60 seconds
```

### Cleanup Command

When RAM falls below 20%, the monitor runs:

```bash
sudo sync && echo 3 | sudo tee /proc/sys/vm/drop_caches && sudo fstrim -A -v
```

### Usage

```sage
# Continuous monitoring loop
cluster_monitor_run(CLUSTER_NODES, CLUSTER_USER, password, 60)

# Single sweep (for shell command)
cluster_monitor_once(CLUSTER_NODES, CLUSTER_USER, password)
```

---

## Test Suite

```bash
# SSH + crypto tests (37 assertions against RFC test vectors)
python3 tests/ssh_test.py

# Sample output:
#   --- SHA-256 Tests ---
#   [PASS] SHA256('')
#   [PASS] SHA256('abc')
#   [PASS] SHA256(448-bit)
#   [PASS] SHA256(1M 'a')
#   --- HMAC-SHA256 Tests ---
#   [PASS] HMAC-SHA256 RFC4231 TC1
#   [PASS] HMAC-SHA256 RFC4231 TC2
#   [PASS] HMAC-SHA256 RFC4231 TC3 (large key)
#   --- SSH Packet Format Tests ---
#   [PASS] SSH uint32 encode
#   [PASS] SSH string encode
#   [PASS] SSH mpint encode (RFC 4251 §5)
#   [PASS] SSH KEXINIT packet format
#   [PASS] SSH AUTH packet format
#   [PASS] SSH CHANNEL_OPEN packet format
#   --- Cluster Monitor Logic ---
#   [PASS] 20% threshold calculation
#   [PASS] Cleanup command matches
#   ALL 37 TESTS PASSED
```

---

## Known Limitations

- **Curve25519**: Key exchange math requires big-integer GF(2^255-19) arithmetic — needs SageVM crypto builtin or host library
- **AES-CTR**: AES block cipher not yet implemented in pure Sage — needs builtin
- **Real SSH connectivity**: Tested against protocol spec; hardware integration pending WiFi + TCP stack completion
- **Password auth only**: Public key authentication requires ed25519 signature verification
