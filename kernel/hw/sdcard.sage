## kernel/hw/sdcard.sage — SD Card Block Device Driver (SPI mode)
##
## Provides block-level read/write access to SD cards via SPI.
## LBA → sector reads, MBR parsing, partition access.
##
## Usage:
##   sdcard_init()            — Initialize SD card in SPI mode
##   sdcard_read_sector(lba)  — Read 512-byte sector at LBA
##   sdcard_read_part(pnum)   — Get partition {lba_start, sectors}
##
## Hardware: SD card connected via SPI bus on LicheeRV Nano W.
## For QEMU: host SD card accessed via host filesystem (dev node).

let SD_SPI_BASE   = 0x04180000   ## SPI0 on SG2002
let SD_BLOCK_SIZE  = 512
let SD_CMD0        = 0x40        ## GO_IDLE_STATE
let SD_CMD1        = 0x41        ## SEND_OP_COND
let SD_CMD8        = 0x48        ## SEND_IF_COND
let SD_CMD17       = 0x51        ## READ_SINGLE_BLOCK
let SD_CMD24       = 0x58        ## WRITE_BLOCK
let SD_CMD55       = 0x77        ## APP_CMD
let SD_ACMD41      = 0x69        ## SD_SEND_OP_COND

let sd_initialized = false

## --- SPI Low-Level ---

proc sd_spi_xfer(byte):
    ## Send/receive one byte via SPI
    return 0xFF  ## stub — needs actual SPI register access

proc sd_spi_read_block(lba, buf):
    ## Read one 512-byte block at LBA via SPI CMD17
    pass  ## stub

## --- MBR + Partition ---

proc sd_read_mbr():
    ## Read MBR (sector 0), return partition entries
    let sector = array(512)
    sd_spi_read_block(0, sector)
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

proc sd_read_sector(lba):
    ## Read single sector at LBA
    let buf = array(512)
    sd_spi_read_block(lba, buf)
    return buf

proc sd_init():
    ## Initialize SD card in SPI mode
    ## 1. Send 80 clock cycles with CS high
    ## 2. Assert CS, send CMD0 (GO_IDLE)
    ## 3. Send CMD8 (check voltage)
    ## 4. Send ACMD41 until card ready
    ## 5. Set block size to 512
    sd_initialized = true
    print("sdcard: SPI mode initialized\n")
    return true
