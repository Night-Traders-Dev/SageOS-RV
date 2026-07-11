## kernel/hw/sdcard.sage — SD Card Block Device Driver (DW-MSHC)
##
## Provides block-level read/write access to SD cards via Synopsys DesignWare MMC.
## Ported from open-source dw_mmc.c implementation.
##
## Hardware: SD card connected via SDHCI0 (0x04310000) on LicheeRV Nano W.

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
let DWMCI_RESP2      = 0x038
let DWMCI_RESP3      = 0x03C
let DWMCI_MINTSTS    = 0x040
let DWMCI_RINTSTS    = 0x044
let DWMCI_STATUS     = 0x048
let DWMCI_FIFOTH     = 0x04C
let DWMCI_CDETECT    = 0x050
let DWMCI_WRTPRT     = 0x054
let DWMCI_BMOD       = 0x080
let DWMCI_DATA       = 0x200

## CTRL register bits
let DWMCI_CTRL_RESET     = 0x01
let DWMCI_CTRL_FIFO_RST  = 0x02
let DWMCI_CTRL_DMA_RST   = 0x04
let DWMCI_CTRL_INT_EN    = 0x10

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

## SD Commands
let SD_CMD0        = 0
let SD_CMD8        = 8
let SD_CMD17       = 17
let SD_CMD24       = 24
let SD_CMD55       = 55
let SD_ACMD41      = 41

let SD_BASE        = 0x04310000  ## SG2002 SDHCI0 base address
let sd_initialized = false

## --- DW-MSHC Low-Level ---

proc dwmci_read32(offset):
    return mem_read(SD_BASE + offset, 4)

proc dwmci_write32(offset, val):
    mem_write(SD_BASE + offset, val, 4)

proc dwmci_wait_reset():
    let timeout = 10000
    while (dwmci_read32(DWMCI_CTRL) & (DWMCI_CTRL_RESET | DWMCI_CTRL_FIFO_RST | DWMCI_CTRL_DMA_RST)) != 0:
        timeout = timeout - 1
        if timeout == 0:
            print("sdcard: DW-MSHC reset timeout\n")
            return false
    return true

proc dwmci_send_cmd(cmd_idx, arg, flags):
    ## Wait for previous command to complete
    let timeout = 100000
    while (dwmci_read32(DWMCI_STATUS) & 0x01) != 0:
        timeout = timeout - 1
        if timeout == 0:
            print("sdcard: DW-MSHC command busy timeout\n")
            return false

    ## Clear interrupts
    dwmci_write32(DWMCI_RINTSTS, 0xFFFFFFFF)

    ## Send command
    dwmci_write32(DWMCI_CMDARG, arg)
    let cmd_val = DWMCI_CMD_START | DWMCI_CMD_USE_HOLD | flags | cmd_idx
    dwmci_write32(DWMCI_CMD, cmd_val)

    ## Wait for command done
    timeout = 100000
    while (dwmci_read32(DWMCI_RINTSTS) & 0x04) == 0:  ## CDONE
        timeout = timeout - 1
        if timeout == 0:
            print("sdcard: DW-MSHC command done timeout\n")
            return false

    ## Check for errors
    let sts = dwmci_read32(DWMCI_RINTSTS)
    if (sts & 0x80) != 0:  ## RTO (Response Timeout)
        return false
    if (sts & 0x40) != 0:  ## RCRC (Response CRC Error)
        ## Some commands do not have CRC, handle carefully
        pass
    
    return true

## --- MBR + Partition ---

proc sd_read_mbr():
    ## Read MBR (sector 0), return partition entries
    let sector = array(512)
    sd_read_sector(0, sector)
    let sig = (sector[510]) | (sector[511] << 8)
    if sig != 0xAA55: return nil
    let parts = array(4)
    let i = 0
    while i < 4:
        let off = 446 + i * 16
        let ptype = sector[off + 4]
        let start = sector[off+8] | (sector[off+9]<<8) | (sector[off+10]<<16) | (sector[off+11]<<24)
        let size  = sector[off+12] | (sector[off+13]<<8) | (sector[off+14]<<16) | (sector[off+15]<<24)
        if ptype != 0 and size > 0:
            push(parts, {type: ptype, lba_start: start, sectors: size, index: i})
        i = i + 1
    return parts

proc sd_read_sector(lba, buf):
    ## Read single sector at LBA
    if not sd_initialized:
        return false
    
    ## Set byte count and block size
    dwmci_write32(DWMCI_BYTCNT, 512)
    dwmci_write32(DWMCI_BLKSIZ, 512)
    
    ## Send CMD17 (READ_SINGLE_BLOCK)
    if not dwmci_send_cmd(SD_CMD17, lba, DWMCI_CMD_RESP_EXP | DWMCI_CMD_DATA_EXP):
        print("sdcard: CMD17 failed\n")
        return false
        
    ## Read data from FIFO
    let i = 0
    while i < 128:
        let word = dwmci_read32(DWMCI_DATA)
        buf[i * 4 + 0] = word & 0xFF
        buf[i * 4 + 1] = (word >> 8) & 0xFF
        buf[i * 4 + 2] = (word >> 16) & 0xFF
        buf[i * 4 + 3] = (word >> 24) & 0xFF
        i = i + 1

    return true

proc sd_init():
    ## Initialize SD card in DW-MSHC mode
    print("sdcard: Initializing DW-MSHC at 0x04310000...\n")
    
    ## 1. Reset controller
    dwmci_write32(DWMCI_CTRL, DWMCI_CTRL_RESET | DWMCI_CTRL_FIFO_RST | DWMCI_CTRL_DMA_RST)
    if not dwmci_wait_reset():
        return false
        
    ## 2. Enable power to card
    dwmci_write32(DWMCI_PWREN, 1)
    
    ## 3. Update clock (send dummy command with UPD_CLK)
    dwmci_write32(DWMCI_CMD, DWMCI_CMD_START | DWMCI_CMD_UPD_CLK | DWMCI_CMD_PRV_DAT_WT)
    
    ## 4. Send CMD0 (GO_IDLE)
    if not dwmci_send_cmd(SD_CMD0, 0, 0):
        print("sdcard: CMD0 failed\n")
        return false
        
    ## 5. Send CMD8 (check voltage)
    if not dwmci_send_cmd(SD_CMD8, 0x1AA, DWMCI_CMD_RESP_EXP):
        print("sdcard: CMD8 failed (legacy card?)\n")
        
    ## 6. Send ACMD41 until card ready
    let ready = false
    let retries = 100
    while retries > 0 and not ready:
        dwmci_send_cmd(SD_CMD55, 0, DWMCI_CMD_RESP_EXP)
        dwmci_send_cmd(SD_ACMD41, 0x40300000, DWMCI_CMD_RESP_EXP)
        let resp = dwmci_read32(DWMCI_RESP0)
        if (resp & 0x80000000) != 0:
            ready = true
        retries = retries - 1
        
    if not ready:
        print("sdcard: ACMD41 timeout\n")
        return false
        
    ## 7. Enable global interrupts
    dwmci_write32(DWMCI_CTRL, dwmci_read32(DWMCI_CTRL) | DWMCI_CTRL_INT_EN)
    
    sd_initialized = true
    print("sdcard: DW-MSHC initialized successfully.\n")
    return true
