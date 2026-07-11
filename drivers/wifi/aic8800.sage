## drivers/wifi/aic8800.sage — AIC8800D WiFi 6 Driver
##
## Reference: aic8800_linux_driver (IPC shared memory protocol)
## LicheeRV Nano W onboard AIC8800D over SDIO.

let AIC_SDIO_BASE   = 0x04320000  ## SDHCI1 on SG2002 (SDIO for WiFi)
let AIC_IPC_BASE    = 0x87000000  ## Shared memory for driver<->firmware IPC
let AIC_FW_BASE     = 0x88000000  ## Firmware load address in DRAM
let AIC_FW_MAX_SIZE = 512 * 1024  ## 512 KB max firmware size

let aic_initialized = false
let aic_fw_loaded   = false
let aic_scan_results = []

## AIC IPC mailbox registers (relative to AIC_IPC_BASE)
let AIC_IPC_MBOX_CTRL = 0x00
let AIC_IPC_MBOX_TX   = 0x04
let AIC_IPC_MBOX_RX   = 0x08
let AIC_IPC_MBOX_STS  = 0x0C

## AIC firmware commands
let AIC_CMD_INIT       = 0x01
let AIC_CMD_SCAN       = 0x02
let AIC_CMD_CONNECT    = 0x03
let AIC_CMD_DISCONNECT = 0x04
let AIC_CMD_GET_STATUS = 0x05

proc ipc_write32(offset, val):
    mem_write(AIC_IPC_BASE + offset, val, 4)

proc ipc_read32(offset):
    return mem_read(AIC_IPC_BASE + offset, 4)

proc ipc_send_cmd(cmd, arg):
    if not aic_fw_loaded:
        return false
    ipc_write32(AIC_IPC_MBOX_TX, arg)
    ipc_write32(AIC_IPC_MBOX_CTRL, cmd)
    let timeout = 10000
    while timeout > 0:
        let sts = ipc_read32(AIC_IPC_MBOX_STS)
        if (sts & 0x01) == 0:
            return true
        timeout = timeout - 1
    return false

proc ipc_recv_resp():
    if not aic_fw_loaded:
        return 0
    let sts = ipc_read32(AIC_IPC_MBOX_STS)
    if (sts & 0x02) != 0:
        return ipc_read32(AIC_IPC_MBOX_RX)
    return 0

proc aic8800_init():
    print("[WiFi] AIC8800D driver initializing\n")
    print("[WiFi] SDIO @ 0x04320000, IPC @ 0x87000000\n")
    
    ## Initialize SDIO bus
    if not sdio_init(AIC_SDIO_BASE):
        print("[WiFi] ERROR: SDIO initialization failed!\n")
        return 0
    
    ## Read Vendor ID and Device ID via CMD52 (Function 0, CIS area)
    let vid_lo = sdio_read8(0, 0x00)
    let vid_hi = sdio_read8(0, 0x01)
    let vid = (vid_hi << 8) | vid_lo
    print("[WiFi] SDIO Vendor ID: 0x")
    print(vid)
    print("\n")
    if vid == 0 or vid == 0xFFFF:
        print("[WiFi] WARNING: No SDIO device detected\n")

    ## Enable SDIO Function 1 (WiFi function)
    sdio_write8(0, 0x03, 0x02)
    
    ## Check firmware blob embedded in .aic_fw section
    let fw_base_addr = AIC_FW_BASE
    let fw_magic = mem_read(fw_base_addr, 4)
    print("[WiFi] Firmware section magic: 0x")
    print(fw_magic)
    print("\n")
    
    if fw_magic == 0x46495741:  ## "AWIF"
        print("[WiFi] Firmware found in .aic_fw section\n")
        aic_fw_loaded = true
    else:
        print("[WiFi] No firmware in .aic_fw section, trying SDIO download...\n")
        let fw_size = __builtin__.aic8800_load_fw()
        if fw_size > 0:
            print("[WiFi] Successfully loaded AIC8800 firmware blob (")
            print(int(fw_size))
            print(" bytes) via SDIO\n")
            aic_fw_loaded = true
        else:
            print("[WiFi] ERROR: Missing or empty AIC8800 firmware blob!\n")
    
    ## Send firmware init command
    if aic_fw_loaded:
        if ipc_send_cmd(AIC_CMD_INIT, 0):
            print("[WiFi] Firmware init command sent OK\n")
            let resp = ipc_recv_resp()
            if resp == 0x01:
                print("[WiFi] Firmware ready\n")
                aic_initialized = true
            else:
                print("[WiFi] Firmware init response: 0x")
                print(resp)
                print("\n")
        else:
            print("[WiFi] WARNING: No IPC response (firmware may need reset)\n")
    
    if aic_initialized:
        print("[WiFi] AIC8800D driver ready.\n")
    else:
        print("[WiFi] AIC8800D driver initialized (limited mode).\n")
    return 0

proc aic8800_scan():
    print("[WiFi] Scanning for networks...\n")
    if not aic_initialized:
        print("[WiFi] ERROR: WiFi not initialized\n")
        return 0
    if ipc_send_cmd(AIC_CMD_SCAN, 0):
        print("[WiFi] Scan command sent, waiting for results...\n")
        let timeout = 100
        while timeout > 0:
            let resp = ipc_recv_resp()
            if resp != 0:
                print("[WiFi] Scan found network\n")
                push(aic_scan_results, resp)
                return resp
            timeout = timeout - 1
    print("[WiFi] Scan complete (no networks found via IPC)\n")
    return 0

proc aic8800_connect(ssid, pwd):
    print("[WiFi] Connecting to: ")
    print(ssid)
    print("\n")
    if not aic_initialized:
        print("[WiFi] ERROR: WiFi not initialized\n")
        return 0
    if ipc_send_cmd(AIC_CMD_CONNECT, 0):
        print("[WiFi] Connection request sent\n")
        let resp = ipc_recv_resp()
        if resp == 0x01:
            print("[WiFi] Connected successfully\n")
            return 1
        print("[WiFi] Connection failed (code: ")
        print(resp)
        print(")\n")
    else:
        print("[WiFi] IPC command failed (firmware may not be ready)\n")
    return 0

proc aic8800_disconnect():
    if aic_initialized:
        ipc_send_cmd(AIC_CMD_DISCONNECT, 0)
    return 0

proc aic8800_get_status():
    if not aic_initialized:
        return 0
    ipc_send_cmd(AIC_CMD_GET_STATUS, 0)
    return ipc_recv_resp()

proc aic8800_get_mac():
    if not aic_initialized:
        return [0, 0, 0, 0, 0, 0]
    let mac_lo = ipc_recv_resp()
    let mac_hi = ipc_recv_resp()
    return [
        (mac_lo >> 0) & 0xFF,
        (mac_lo >> 8) & 0xFF,
        (mac_lo >> 16) & 0xFF,
        (mac_lo >> 24) & 0xFF,
        (mac_hi >> 0) & 0xFF,
        (mac_hi >> 8) & 0xFF
    ]
