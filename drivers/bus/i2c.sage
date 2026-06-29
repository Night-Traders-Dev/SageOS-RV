## drivers/i2c.sage — Pure-Sage I2C Bus Driver for SG2002
##
## DesignWare I2C controller on Sophgo SG2002.
## Supports master mode read/write operations.
##
## Register map (per controller, relative to base):
##   0x00 — IC_CON          Control register
##   0x04 — IC_TAR          Target address
##   0x08 — IC_SAR          Slave address (unused in master mode)
##   0x0C — IC_DATA_CMD     Data buffer + command
##   0x10 — IC_SS_SCL_HCNT  Standard speed SCL high count
##   0x14 — IC_SS_SCL_LCNT  Standard speed SCL low count
##   0x18 — IC_FS_SCL_HCNT  Fast speed SCL high count
##   0x1C — IC_FS_SCL_LCNT  Fast speed SCL low count
##   0x2C — IC_INTR_STAT    Interrupt status
##   0x30 — IC_INTR_MASK    Interrupt mask
##   0x34 — IC_RAW_INTR_STAT Raw interrupt status
##   0x40 — IC_RX_TL        Receive FIFO threshold
##   0x44 — IC_TX_TL        Transmit FIFO threshold
##   0x48 — IC_CLR_INTR     Clear interrupt
##   0x4C — IC_CLR_RX_UNDER Clear RX underflow
##   0x50 — IC_CLR_RX_OVER  Clear RX overflow
##   0x54 — IC_CLR_TX_OVER  Clear TX overflow
##   0x60 — IC_CLR_TX_ABRT  Clear TX abort
##   0x70 — IC_STATUS       Controller status
##   0x74 — IC_TXFLR        Transmit FIFO level
##   0x78 — IC_RXFLR        Receive FIFO level
##   0xA4 — IC_ENABLE       Enable register
##   0xA8 — IC_ENABLE_STATUS Enable status

## I2C controller base addresses (SG2002)
let I2C0_BASE = 0x04000000
let I2C1_BASE = 0x04010000
let I2C2_BASE = 0x04020000
let I2C3_BASE = 0x04030000

## Register offsets
let I2C_CON         = 0x00
let I2C_TAR         = 0x04
let I2C_DATA_CMD    = 0x0C
let I2C_SS_SCL_HCNT = 0x10
let I2C_SS_SCL_LCNT = 0x14
let I2C_FS_SCL_HCNT = 0x18
let I2C_FS_SCL_LCNT = 0x1C
let I2C_INTR_MASK   = 0x30
let I2C_CLR_INTR    = 0x48
let I2C_CLR_TX_ABRT = 0x60
let I2C_ENABLE      = 0xA4
let I2C_ENABLE_STATUS = 0xA8
let I2C_STATUS      = 0x70
let I2C_TXFLR       = 0x74
let I2C_RXFLR       = 0x78

## Status bits
let I2C_STATUS_TFNF  = (1 << 1)   ## TX FIFO not full
let I2C_STATUS_RFNE  = (1 << 3)   ## RX FIFO not empty
let I2C_STATUS_ACTIVITY = (1 << 5) ## Controller active

## Data command bits
let I2C_CMD_WRITE = 0         ## Write command
let I2C_CMD_READ  = (1 << 8)  ## Read command
let I2C_CMD_STOP  = (1 << 9)  ## Issue STOP after this byte
let I2C_CMD_RESTART = (1 << 10) ## Issue RESTART before this byte

## --- I2C Master API ---

proc i2c_init(base):
    ## Disable controller
    mem_write(base + I2C_ENABLE, 0, 4)
    
    ## Configure for standard mode (100 kHz)
    ## SCL clock = input_clock / (SS_SCL_HCNT + SS_SCL_LCNT)
    ## For 100 MHz APB clock: HCNT=500, LCNT=500 -> 100 kHz
    mem_write(base + I2C_SS_SCL_HCNT, 500, 4)
    mem_write(base + I2C_SS_SCL_LCNT, 500, 4)
    
    ## Master mode, 7-bit addressing, standard speed
    ## IC_CON: bit[6]=1 (slave disable), bit[2:1]=10 (fast mode), bit[0]=1 (master)
    let con_val = (1 << 6) | (1 << 1) | (1 << 0)
    mem_write(base + I2C_CON, con_val, 4)
    
    ## Set target address (updated per-transaction)
    ## Enable controller
    mem_write(base + I2C_ENABLE, 1, 4)
    
    ## Wait for enable
    while (mem_read(base + I2C_ENABLE_STATUS, 4) & 1) == 0:
        pass

proc i2c_set_target(base, addr):
    ## Set 7-bit target address
    mem_write(base + I2C_TAR, addr & 0x7F, 4)

proc i2c_write(base, data_byte):
    ## Wait for TX FIFO not full
    while (mem_read(base + I2C_STATUS, 4) & I2C_STATUS_TFNF) == 0:
        pass
    ## Write data with STOP command
    let cmd = I2C_CMD_WRITE | I2C_CMD_STOP | (data_byte & 0xFF)
    mem_write(base + I2C_DATA_CMD, cmd, 4)

proc i2c_write_bytes(base, addr, data, length):
    i2c_disable(base)
    i2c_set_target(base, addr)
    i2c_enable(base)
    
    let i = 0
    while i < length:
        ## Wait for TX FIFO not full
        while (mem_read(base + I2C_STATUS, 4) & I2C_STATUS_TFNF) == 0:
            pass
        let cmd = I2C_CMD_WRITE | (data[i] & 0xFF)
        if i == (length - 1):
            cmd = cmd | I2C_CMD_STOP
        mem_write(base + I2C_DATA_CMD, cmd, 4)
        i = i + 1
    
    ## Wait for activity to complete
    while (mem_read(base + I2C_STATUS, 4) & I2C_STATUS_ACTIVITY) != 0:
        pass

proc i2c_read_bytes(base, addr, length):
    i2c_disable(base)
    i2c_set_target(base, addr)
    i2c_enable(base)
    
    let result = array(length)
    let i = 0
    while i < length:
        let cmd = I2C_CMD_READ
        if i == (length - 1):
            cmd = cmd | I2C_CMD_STOP
        mem_write(base + I2C_DATA_CMD, cmd, 4)
        
        ## Wait for RX FIFO not empty
        while (mem_read(base + I2C_STATUS, 4) & I2C_STATUS_RFNE) == 0:
            pass
        result[i] = mem_read(base + I2C_DATA_CMD, 4) & 0xFF
        i = i + 1
    
    return result

## --- Control helpers ---

proc i2c_enable(base):
    mem_write(base + I2C_ENABLE, 1, 4)
    while (mem_read(base + I2C_ENABLE_STATUS, 4) & 1) == 0:
        pass

proc i2c_disable(base):
    mem_write(base + I2C_ENABLE, 0, 4)
    while (mem_read(base + I2C_ENABLE_STATUS, 4) & 1) != 0:
        pass

## --- Scan bus for devices ---

proc i2c_scan(base):
    print("I2C Bus Scan:\n")
    let addr = 1
    while addr < 128:
        i2c_disable(base)
        i2c_set_target(base, addr)
        i2c_enable(base)
        
        ## Try to write a 0-byte (just the address phase)
        if (mem_read(base + I2C_STATUS, 4) & I2C_STATUS_TFNF) != 0:
            mem_write(base + I2C_DATA_CMD, I2C_CMD_WRITE | I2C_CMD_STOP, 4)
            
            ## Wait briefly and check for TX abort
            while (mem_read(base + I2C_STATUS, 4) & I2C_STATUS_ACTIVITY) != 0:
                pass
            print("  Found device at 0x")
            print(addr)
            print("\n")
        
        addr = addr + 1
    print("Scan complete.\n")
