## drivers/bus/sdio.sage — SDIO Bus Driver (DW-MSHC)
##
## Provides SDIO CMD52 (byte) and CMD53 (block) operations over the
## Synopsys DesignWare MMC controller (DW-MSHC). Used primarily for WiFi.

let DWMCI_CTRL       = 0x000
let DWMCI_PWREN      = 0x004
let DWMCI_CLKDIV     = 0x008
let DWMCI_CLKSRC     = 0x00C
let DWMCI_CLKENA     = 0x010
let DWMCI_TMOUT      = 0x014
let DWMCI_CTYPE      = 0x018
let DWMCI_BLKSIZ     = 0x01C
let DWMCI_BYTCNT     = 0x020
let DWMCI_INTMASK    = 0x024
let DWMCI_CMDARG     = 0x028
let DWMCI_CMD        = 0x02C
let DWMCI_RESP0      = 0x030
let DWMCI_RESP1      = 0x034
let DWMCI_RINTSTS    = 0x044
let DWMCI_STATUS     = 0x048
let DWMCI_DATA       = 0x200

## CMD register bits
let DWMCI_CMD_START      = 0x80000000
let DWMCI_CMD_USE_HOLD   = 0x20000000
let DWMCI_CMD_UPD_CLK    = 0x200000
let DWMCI_CMD_PRV_DAT_WT = 0x2000
let DWMCI_CMD_RESP_EXP   = 0x40
let DWMCI_CMD_RESP_LONG  = 0x80
let DWMCI_CMD_RESP_CRC   = 0x100
let DWMCI_CMD_DATA_EXP   = 0x200
let DWMCI_CMD_RW         = 0x400

let SD_CMD3  = 3
let SD_CMD5  = 5
let SD_CMD7  = 7
let SD_CMD52 = 52
let SD_CMD53 = 53

let sdio_base = 0
let sdio_rca  = 0

proc sdio_init(base_addr):
    sdio_base = base_addr
    print("sdio: Initializing DW-MSHC SDIO at ")
    print(int(sdio_base))
    print("\n")

    ## 1. Reset
    mem_write(sdio_base + DWMCI_CTRL, 0x07, 4)
    let timeout = 10000
    while (mem_read(sdio_base + DWMCI_CTRL, 4) & 0x07) != 0 and timeout > 0:
        timeout = timeout - 1
    
    ## 2. Power on
    mem_write(sdio_base + DWMCI_PWREN, 1, 4)
    
    ## 3. Dummy clock update
    mem_write(sdio_base + DWMCI_CMD, DWMCI_CMD_START | DWMCI_CMD_UPD_CLK | DWMCI_CMD_PRV_DAT_WT, 4)

    ## 4. Send CMD0
    sdio_send_cmd(0, 0, 0)
    
    ## 5. Send CMD5 (SDIO IO_SEND_OP_COND)
    if not sdio_send_cmd(SD_CMD5, 0, DWMCI_CMD_RESP_EXP):
        print("sdio: CMD5 failed\n")
        return false
    
    ## 6. Send CMD3 (Get RCA)
    if not sdio_send_cmd(SD_CMD3, 0, DWMCI_CMD_RESP_EXP):
        print("sdio: CMD3 failed\n")
        return false
    sdio_rca = mem_read(sdio_base + DWMCI_RESP0, 4) >> 16
    
    ## 7. Send CMD7 (Select Card)
    sdio_send_cmd(SD_CMD7, sdio_rca << 16, DWMCI_CMD_RESP_EXP)
    
    return true

proc sdio_send_cmd(cmd_idx, arg, flags):
    let timeout = 100000
    while (mem_read(sdio_base + DWMCI_STATUS, 4) & 0x01) != 0 and timeout > 0:
        timeout = timeout - 1
        
    mem_write(sdio_base + DWMCI_RINTSTS, 0xFFFFFFFF, 4)
    mem_write(sdio_base + DWMCI_CMDARG, arg, 4)
    mem_write(sdio_base + DWMCI_CMD, DWMCI_CMD_START | DWMCI_CMD_USE_HOLD | flags | cmd_idx, 4)
    
    timeout = 100000
    while (mem_read(sdio_base + DWMCI_RINTSTS, 4) & 0x04) == 0 and timeout > 0:
        timeout = timeout - 1
        
    let sts = mem_read(sdio_base + DWMCI_RINTSTS, 4)
    if (sts & 0x80) != 0:
        return false
    return true

proc sdio_read8(func, addr):
    ## CMD52: RW=0, Function=func, RAW=0, Addr=addr, Data=0
    let arg = (0 << 31) | ((func & 7) << 28) | ((addr & 0x1FFFF) << 9)
    if not sdio_send_cmd(SD_CMD52, arg, DWMCI_CMD_RESP_EXP):
        return -1
    let resp = mem_read(sdio_base + DWMCI_RESP0, 4)
    return resp & 0xFF

proc sdio_write8(func, addr, val):
    ## CMD52: RW=1, Function=func, RAW=0, Addr=addr, Data=val
    let arg = (1 << 31) | ((func & 7) << 28) | ((addr & 0x1FFFF) << 9) | (val & 0xFF)
    return sdio_send_cmd(SD_CMD52, arg, DWMCI_CMD_RESP_EXP)
