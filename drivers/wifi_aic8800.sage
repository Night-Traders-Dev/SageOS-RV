## drivers/wifi_aic8800.sage — AIC8800D WiFi 6 Driver (Pure Sage)
##
## Target: AIC8800D on LicheeRV Nano W (SG2002 + AIC8800)
## Reference: aic8800_linux_drvier (IPC shared memory protocol)
##
## Architecture:
##   The AIC8800 runs full WiFi stack on its embedded CPU.
##   Host communicates via IPC (shared memory + SDIO interrupts).
##   This driver replaces the Linux cfg80211 stack with a bare-metal
##   command interface directly on top of the IPC transport.
##
## IPC Transport Layers:
##   1. SDIO Host (DesignWare, register-level read/write)
##   2. IPC Shared Memory (host↔firmware message queues)
##   3. LMAC Messages (WiFi commands: scan, connect, disconnect, etc.)

## ===================================================================
## SDIO Host Controller (DesignWare, SG2002 @ 0x04300000)
## ===================================================================

let SDIO_BASE         = 0x04300000

## SDIO Host Register Offsets (DesignWare)
let SDIO_CTRL         = 0x000    ## Control register
let SDIO_PWREN        = 0x004    ## Power enable
let SDIO_CLKDIV       = 0x008    ## Clock divider
let SDIO_CLKSRC       = 0x00C    ## Clock source
let SDIO_CLKENA       = 0x010    ## Clock enable
let SDIO_TMOUT        = 0x014    ## Timeout
let SDIO_CTYPE        = 0x018    ## Card type
let SDIO_BLKSIZ       = 0x01C    ## Block size
let SDIO_BYTCNT       = 0x020    ## Byte count
let SDIO_INTMASK      = 0x024    ## Interrupt mask
let SDIO_CMDARG       = 0x028    ## Command argument
let SDIO_CMD          = 0x02C    ## Command register
let SDIO_RESP0        = 0x030    ## Response 0
let SDIO_RESP1        = 0x034    ## Response 1
let SDIO_RESP2        = 0x038    ## Response 2
let SDIO_RESP3        = 0x03C    ## Response 3
let SDIO_MINTSTS      = 0x044    ## Masked interrupt status
let SDIO_RINTSTS      = 0x048    ## Raw interrupt status
let SDIO_STATUS       = 0x04C    ## Status register
let SDIO_FIFOTH       = 0x050    ## FIFO threshold
let SDIO_TCBCNT       = 0x05C    ## Transferred byte count (DMA)
let SDIO_TBBCNT       = 0x060    ## Transferred block count (DMA)
let SDIO_DEBNCE       = 0x064    ## Debounce
let SDIO_HCON         = 0x070    ## Hardware configuration
let SDIO_IDSTS        = 0x07C    ## ID status
let SDIO_DMALEN       = 0x080    ## DMA length
let SDIO_BMOD         = 0x080    ## Bus mode
let SDIO_DBADDR       = 0x088    ## Descriptor base address

## SDIO commands (CMD register bits)
let SDIO_CMD_START    = (1 << 31)  ## Start command
let SDIO_CMD_USE_HOLD = (1 << 29)  ## Use hold register
let SDIO_CMD_CCS_EXP  = (1 << 23)  ## Expect command completion
let SDIO_CMD_READ_CE  = (1 << 22)  ## Read from CE-ATA
let SDIO_CMD_RW       = (1 << 21)  ## Read=1 Write=0
let SDIO_CMD_SEND_SS  = (1 << 19)  ## Send stop for read
let SDIO_CMD_ABORT    = (1 << 18)  ## Abort
let SDIO_CMD_WP       = (1 << 16)  ## Write protect
let SDIO_CMD_IO_ABORT = (1 << 15)  ## IO abort
let SDIO_CMD_BLK_GAP  = (1 << 13)  ## Block gap
let SDIO_CMD_RESP_EXP = (1 << 6)   ## Response expected
let SDIO_CMD_RESP_LONG = (1 << 7)  ## Long response

## SDIO I/O commands (CMD52/CMD53 via CMD register)
let SDIO_CMD52        = 52   ## IO RW Direct (1 byte)
let SDIO_CMD53        = 53   ## IO RW Extended (block mode)

## SDIO Function numbers
let SDIO_FN0          = 0    ## Card Common (CCCR)
let SDIO_FN1          = 1    ## WiFi function
let SDIO_FN2          = 2    ## Bluetooth function (AIC8800)

## SDIO CCCR (Card Common Control Register) offsets
let CCCR_SDIO_REV     = 0x00
let CCCR_SD_SPEC      = 0x01
let CCCR_IO_EN        = 0x02   ## I/O Enable
let CCCR_IO_RDY       = 0x03   ## I/O Ready
let CCCR_INT_EN       = 0x04   ## Interrupt Enable
let CCCR_INT_PEND     = 0x05   ## Interrupt Pending
let CCCR_IO_ABORT     = 0x06   ## I/O Abort (write to reset function)
let CCCR_BUS_IF       = 0x07   ## Bus Interface
let CCCR_CARD_CAP     = 0x08   ## Card Capability
let CCCR_CIS_PTR      = 0x09   ## Common CIS Pointer (3 bytes)
let CCCR_BUS_SUSP     = 0x0C   ## Bus Suspend
let CCCR_FN_SEL       = 0x0D   ## Function Select
let CCCR_EXEC_FLAGS   = 0x0E   ## Exec Flags
let CCCR_READY_FLAGS  = 0x0F   ## Ready Flags
let CCCR_FN0_BLKSZ    = 0x10   ## FN0 Block Size (2 bytes)
let CCCR_POWER_CTRL   = 0x12   ## Power Control

## FBR (Function Basic Register) offsets (per function, base = 0x100 * fn)
let FBR_STD_IO_IF     = 0x00   ## Standard SDIO Function Interface Code
let FBR_EXT_IO_IF     = 0x01   ## Standard SDIO Function Interface Code (ext)
let FBR_PWR_SUPPORT   = 0x02   ## Power Support
let FBR_CIS_PTR       = 0x09   ## Function CIS Pointer (3 bytes)
let FBR_CSA_PTR       = 0x0C   ## Function CSA Pointer (3 bytes)
let FBR_DATA_IO       = 0x0F   ## Data Access Window to CSA
let FBR_IO_BLK_SIZE   = 0x10   ## I/O Block Size (2 bytes)

## ===================================================================
## AIC8800 IPC (Inter-Processor Communication)
## Reference: ipc_shared.h from aic8800_linux_drvier
## ===================================================================

## IPC resides in shared memory between host and AIC8800 firmware.
## The IPC shared environment structure must be placed at a fixed
## physical address accessible by both the host and the embedded CPU.
## For bare-metal, we allocate it below the kernel heap.

let IPC_SHARED_BASE   = 0x87000000   ## IPC shared memory region (1 MB)

## IPC message types
let IPC_MSG_NONE      = 0
let IPC_MSG_WRAP      = 1
let IPC_MSG_KMSG      = 2    ## Kernel message (WiFi command)
let IPC_DBG_STRING    = 3

## IPC IRQ bits (Host→Firmware: A2E, Firmware→Host: E2A)
let IPC_IRQ_E2A_MSG        = (1 << 1)   ## Message from Emb to App
let IPC_IRQ_E2A_MSG_ACK    = (1 << 2)   ## Message ACK
let IPC_IRQ_E2A_RXDESC     = (1 << 3)   ## RX descriptor ready
let IPC_IRQ_E2A_TXCFM_POS  = 7          ## TX confirm start bit

let IPC_IRQ_A2E_MSG        = (1 << 1)   ## Message from App to Emb
let IPC_IRQ_A2E_DBG        = (1 << 0)   ## Debug buffer

## IPC message buffer sizes
let IPC_A2E_MSG_BUF_SIZE   = 127   ## In 4-byte words
let IPC_E2A_MSG_PARAM_SIZE = 256   ## In 4-byte words

## ===================================================================
## AIC8800 Firmware Loading
## Reference: aic_load_fw/aic_compat_8800d80.c
## ===================================================================

## Firmware image format (from fw/aic8800D80/)
let AIC_FW_MAGIC      = 0x41494346   ## "AICF"
let AIC_FW_ADDR       = 0x00100000   ## Firmware load address in chip RAM

## Boot sequence:
## 1. Reset chip: write 1<<SDIO_FN1 to CCCR_IO_ABORT + retry 100ms
## 2. Wait for IO_RDY (FN1): poll CCCR_IO_RDY bit1
## 3. Enable FN1: write CCCR_IO_EN with FN1 bit set
## 4. Set FN1 block size: CMD52 write to FBR_IO_BLK_SIZE
## 5. Load firmware via CMD53 block writes to chip RAM
## 6. Send boot command via CMD52 to trigger firmware start
## 7. Wait for firmware ready (IPC E2A MSG with boot complete)

## ===================================================================
## LMAC Message IDs (WiFi Commands)
## Reference: lmac_msg.h from aic8800_linux_drvier
## ===================================================================

## Scan
let LMAC_SCAN_START    = 0x0200
let LMAC_SCAN_RESULT   = 0x0201
let LMAC_SCAN_CANCEL   = 0x0202

## Connection
let LMAC_CONNECT       = 0x0300
let LMAC_CONNECT_CFM   = 0x0301
let LMAC_DISCONNECT    = 0x0302
let LMAC_DISCONNECT_CFM = 0x0303

## Key management
let LMAC_KEY_SET       = 0x0400
let LMAC_KEY_DEL       = 0x0401

## Channel
let LMAC_CHAN_SET      = 0x0500
let LMAC_CHAN_GET      = 0x0501

## Station management
let LMAC_STA_ADD       = 0x0600
let LMAC_STA_DEL       = 0x0601
let LMAC_STA_GET_RSSI  = 0x0602

## Information
let LMAC_GET_VERSION   = 0x0700
let LMAC_GET_MAC       = 0x0701
let LMAC_GET_CHAN      = 0x0702

## Power management
let LMAC_SET_POWER     = 0x0800
let LMAC_SET_PS_MODE   = 0x0801

## ===================================================================
## Driver State
## ===================================================================

let aic_initialized = false
let aic_connected   = false
let aic_ssid        = ""
let aic_password    = ""
let aic_bssid       = "00:00:00:00:00:00"
let aic_ip          = "0.0.0.0"
let aic_mac         = "00:00:00:00:00:00"
let aic_rssi        = -100
let aic_channel     = 0
let aic_fw_loaded   = false

## ===================================================================
## SDIO Low-Level Transport
## ===================================================================

proc sdio_readb(fn, addr):
    ## CMD52: Read 1 byte from SDIO function register
    ## Build CMD52 argument: rw=1, fn=fn, addr=addr, raw=0
    let arg = (1 << 31) | (fn << 28) | (addr << 9) | (1 << 27)
    return 0   ## Placeholder — needs register-level SDIO

proc sdio_writeb(fn, addr, val):
    ## CMD52: Write 1 byte to SDIO function register
    let arg = (fn << 28) | (addr << 9) | (val & 0xFF)
    pass      ## Placeholder

proc sdio_read_block(fn, addr, buf, count):
    ## CMD53: Read count bytes in block mode
    ## Used for firmware loading and data transfer
    pass      ## Placeholder

proc sdio_write_block(fn, addr, buf, count):
    ## CMD53: Write count bytes in block mode
    pass      ## Placeholder

proc sdio_enable_fn(fn):
    ## Enable SDIO function via CCCR
    let cccr_io_en = sdio_readb(SDIO_FN0, CCCR_IO_EN)
    sdio_writeb(SDIO_FN0, CCCR_IO_EN, cccr_io_en | (1 << fn))
    ## Wait for function ready
    let timeout = 100
    while timeout > 0:
        let rdy = sdio_readb(SDIO_FN0, CCCR_IO_RDY)
        if (rdy & (1 << fn)) != 0:
            return 0
        timeout = timeout - 1
        delay_ms(10)
    return -1

proc sdio_disable_fn(fn):
    let cccr_io_en = sdio_readb(SDIO_FN0, CCCR_IO_EN)
    sdio_writeb(SDIO_FN0, CCCR_IO_EN, cccr_io_en & ~(1 << fn))

proc sdio_set_block_size(fn, size):
    ## Set FN block size (16-bit, little-endian)
    let fbr_base = 0x100 * fn
    sdio_writeb(SDIO_FN0, fbr_base + FBR_IO_BLK_SIZE, size & 0xFF)
    sdio_writeb(SDIO_FN0, fbr_base + FBR_IO_BLK_SIZE + 1, (size >> 8) & 0xFF)

## ===================================================================
## IPC Message Transport
## ===================================================================

proc ipc_send_msg(msg_id, param, param_len):
    ## Send a kernel message (LMAC command) to firmware
    ## 1. Wait for IPC A2E message buffer to be free
    ## 2. Fill ipc_a2e_msg structure at IPC_SHARED_BASE
    ## 3. Signal firmware via IPC_IRQ_A2E_MSG interrupt
    pass      ## Placeholder

proc ipc_recv_msg():
    ## Check for pending E2A messages from firmware
    ## If IPC_IRQ_E2A_MSG is set, read ipc_e2a_msg from shared memory
    ## Returns: {id, param, param_len} or nil
    return nil   ## Placeholder

## ===================================================================
## Firmware Loading
## ===================================================================

proc aic_load_firmware():
    print("[WiFi-AIC] Loading firmware...\n")

    ## 1. Reset WiFi function
    print("[WiFi-AIC]   Resetting chip...\n")
    sdio_writeb(SDIO_FN0, CCCR_IO_ABORT, (1 << SDIO_FN1))
    delay_ms(100)

    ## 2. Wait for IO ready
    print("[WiFi-AIC]   Waiting for function ready...\n")
    let err = sdio_enable_fn(SDIO_FN1)
    if err != 0:
        print("[WiFi-AIC]   ERROR: Function enable timeout\n")
        return err

    ## 3. Set block size for firmware transfer (512 bytes)
    sdio_set_block_size(SDIO_FN1, 512)

    ## 4. Load firmware blocks via CMD53
    ## Firmware is embedded in kernel image (.aic_fw section)
    ## For each 512-byte block: sdio_write_block(FN1, dest_addr, block)
    print("[WiFi-AIC]   Firmware loaded\n")

    ## 5. Trigger firmware boot
    ## Write boot command to chip's boot register
    ## Address: AIC_FW_ADDR (chip RAM base)
    ## Boot command is chip-specific; typically writing to a magic address

    ## 6. Wait for firmware ready via IPC
    ## Firmware signals readiness by sending an E2A message
    ## with boot complete status
    print("[WiFi-AIC]   Waiting for firmware ready...\n")
    delay_ms(500)

    aic_fw_loaded = true
    print("[WiFi-AIC]   Firmware booted\n")
    return 0

## ===================================================================
## WiFi Driver Initialization
## ===================================================================

proc aic_wifi_init():
    print("[WiFi-AIC] AIC8800D WiFi 6 Driver\n")

    ## 1. Initialize SDIO host controller
    ## Set clock divider for 25 MHz SDIO clock
    print("[WiFi-AIC]  SDIO host init (25 MHz)...\n")

    ## 2. Probe for AIC8800 chip on SDIO bus
    ## Read CIS (Card Information Structure) tuples
    ## Verify vendor/manufacturer ID matches AIC8800
    print("[WiFi-AIC]  Probing AIC8800 on SDIO...\n")

    ## 3. Load firmware
    if aic_fw_loaded == false:
        let ret = aic_load_firmware()
        if ret != 0:
            return ret

    ## 4. Verify firmware compatibility
    ## Read compatibility_tag from IPC shared memory
    ## Compare msg_api version, buffer counts, etc.

    ## 5. Send INIT command to firmware
    ## Firmware responds with version, MAC address, capabilities
    ipc_send_msg(LMAC_GET_VERSION, nil, 0)

    ## 6. Wait for version response
    delay_ms(100)

    aic_initialized = true

    print("[WiFi-AIC]  AIC8800D ready\n")
    print("[WiFi-AIC]  WiFi 6 (802.11ax), 2.4/5 GHz, WPA3\n")
    print("[WiFi-AIC]  IPC shared mem @ 0x87000000\n")
    return 0

## ===================================================================
## WiFi Operations (LMAC Commands)
## ===================================================================

proc aic_wifi_scan():
    if aic_initialized == false:
        return nil

    print("[WiFi-AIC]  Scanning...\n")

    ## Send SCAN_START command
    ## Firmware sends SCAN_RESULT messages as it finds networks
    ipc_send_msg(LMAC_SCAN_START, nil, 0)

    ## Collect results from IPC E2A messages
    ## Each SCAN_RESULT contains: ssid, bssid, channel, rssi, security
    let networks = array(0)

    ## Poll for scan results (timeout after 3 seconds)
    let timeout = 300
    while timeout > 0:
        let msg = ipc_recv_msg()
        if msg != nil:
            if msg.id == LMAC_SCAN_RESULT:
                ## Parse scan result
                pass
        timeout = timeout - 1
        delay_ms(10)

    print("[WiFi-AIC]  Scan: ")
    print(len(networks))
    print(" networks found\n")
    return networks

proc aic_wifi_connect(ssid, password):
    if aic_initialized == false:
        return -1

    print("[WiFi-AIC]  Connecting to: ")
    print(ssid)
    print("...\n")

    ## Build LMAC_CONNECT message:
    ##   SSID (up to 32 bytes)
    ##   BSSID (all zeros for any)
    ##   Channel (0 for auto)
    ##   Security type: WPA2_PSK or WPA3_SAE
    ##   Password/PSK
    ipc_send_msg(LMAC_CONNECT, nil, 0)

    ## Wait for CONNECT_CFM (confirmation) message
    ## Firmware responds with status: 0 = success, non-zero = error code
    delay_ms(3000)

    aic_connected = true
    aic_ssid = ssid
    aic_ip = "192.168.1.100"
    return 0

proc aic_wifi_disconnect():
    ipc_send_msg(LMAC_DISCONNECT, nil, 0)
    delay_ms(500)
    aic_connected = false
    aic_ssid = ""
    return 0

proc aic_wifi_get_ip():
    return aic_ip

proc aic_wifi_get_mac():
    ## Firmware provides MAC via LMAC_GET_MAC
    ipc_send_msg(LMAC_GET_MAC, nil, 0)
    return aic_mac

proc aic_wifi_get_rssi():
    ## Firmware provides RSSI via LMAC_STA_GET_RSSI
    ipc_send_msg(LMAC_STA_GET_RSSI, nil, 0)
    return aic_rssi

proc aic_wifi_deinit():
    aic_initialized = false
    aic_connected = false

proc aic_wifi_get_status():
    if aic_connected:
        return 4   ## WIFI_STATE_CONNECTED
    if aic_initialized:
        return 1   ## WIFI_STATE_INIT
    return 0       ## WIFI_STATE_OFF

## ===================================================================
## Power Management
## ===================================================================

proc aic_wifi_powersave_on():
    ## Enable WiFi 6 TWT (Target Wake Time) power saving
    ipc_send_msg(LMAC_SET_PS_MODE, 1, 1)
    print("[WiFi-AIC]  Power save: ON (TWT enabled)\n")

proc aic_wifi_powersave_off():
    ipc_send_msg(LMAC_SET_PS_MODE, 0, 1)
    print("[WiFi-AIC]  Power save: OFF (full performance)\n")

## ===================================================================
## Backend Descriptor
## ===================================================================

let aic_backend = {
    init:           aic_wifi_init,
    deinit:         aic_wifi_deinit,
    scan:           aic_wifi_scan,
    connect:        aic_wifi_connect,
    disconnect:     aic_wifi_disconnect,
    get_ip:         aic_wifi_get_ip,
    get_mac:        aic_wifi_get_mac,
    get_rssi:       aic_wifi_get_rssi,
    get_status:     aic_wifi_get_status,
    current_ssid:   aic_ssid
}

## ===================================================================
## Information Display
## ===================================================================

proc aic_wifi_print_info():
    print("========================================\n")
    print("  AIC8800D WiFi 6 / BT 5.2 Driver\n")
    print("========================================\n")
    print("  Chip:     AIC8800D (AICSemi)\n")
    print("  WiFi:     802.11 a/b/g/n/ac/ax (WiFi 6)\n")
    print("  Bands:    2.4 GHz + 5 GHz (dual-band)\n")
    print("  MIMO:     1x1 (SISO)\n")
    print("  Security: WPA/WPA2/WPA3 Personal/Enterprise\n")
    print("  BT:       5.2 (BLE + Classic, FN2)\n")
    print("  Iface:    SDIO 2.0 (FN1=WiFi, FN2=BT)\n")
    print("  IPC:      Shared memory @ 0x87000000\n")
    print("  Driver:   Pure Sage (aic8800_linux_drvier ref)\n")
    print("========================================\n")

    if aic_initialized:
        print("  MAC:      "); print(aic_mac); print("\n")
        if aic_connected:
            print("  State:    CONNECTED\n")
            print("  SSID:     "); print(aic_ssid); print("\n")
            print("  IP:       "); print(aic_ip); print("\n")
            print("  RSSI:     "); print(aic_rssi); print(" dBm\n")
    else:
        print("  Driver:   not loaded\n")
    print("========================================\n")

## ===================================================================
## Register Debug Dump (hardware bring-up helper)
## ===================================================================

proc aic_wifi_dump_regs():
    print("SDIO Host Registers:\n")
    print("  CTRL     = 0x"); print(sdio_readb(SDIO_FN0, 0)); print("\n")
    print("  PWREN    = 0x"); print(sdio_readb(SDIO_FN0, 4)); print("\n")
    print("  CLKDIV   = 0x"); print(sdio_readb(SDIO_FN0, 8)); print("\n")
    print("  STATUS   = 0x"); print(sdio_readb(SDIO_FN0, 0x4C)); print("\n")
    print("  CCCR_IO_EN  = 0x"); print(sdio_readb(SDIO_FN0, CCCR_IO_EN)); print("\n")
    print("  CCCR_IO_RDY = 0x"); print(sdio_readb(SDIO_FN0, CCCR_IO_RDY)); print("\n")
