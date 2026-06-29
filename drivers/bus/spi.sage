## drivers/spi.sage — Pure-Sage SPI Bus Driver for SG2002
##
## DesignWare SPI controller on Sophgo SG2002.
## Supports master mode full-duplex transfers.
##
## Register map (per controller, relative to base):
##   0x00 — CTRLR0      Control register 0
##   0x04 — CTRLR1      Control register 1 (number of data frames)
##   0x08 — SSIENR      SSI enable register
##   0x0C — MWCR        Microwire control (unused)
##   0x10 — SER         Slave enable register
##   0x14 — BAUDR       Baud rate divisor
##   0x18 — TXFTLR      Transmit FIFO threshold
##   0x1C — RXFTLR      Receive FIFO threshold
##   0x20 — TXFLR       Transmit FIFO level
##   0x24 — RXFLR       Receive FIFO level
##   0x28 — SR          Status register
##   0x2C — IMR         Interrupt mask
##   0x30 — ISR         Interrupt status
##   0x34 — RISR        Raw interrupt status
##   0x38 — TXOICR      TX overrun interrupt clear
##   0x3C — RXOICR      RX overrun interrupt clear
##   0x40 — RXUICR      RX underrun interrupt clear
##   0x44 — MSTICR      Multi-master interrupt clear
##   0x48 — ICR         Interrupt clear
##   0x4C — DMACR       DMA control
##   0x50 — DMATDLR     DMA transmit data level
##   0x54 — DMARDLR     DMA receive data level
##   0x60 — DR          Data register (32-bit FIFO access)

## SPI controller base addresses (SG2002)
let SPI0_BASE = 0x04180000
let SPI1_BASE = 0x04181000
let SPI2_BASE = 0x04182000
let SPI3_BASE = 0x04183000

## Register offsets
let SPI_CTRLR0  = 0x00
let SPI_CTRLR1  = 0x04
let SPI_ENABLE  = 0x08
let SPI_SER     = 0x10
let SPI_BAUDR   = 0x14
let SPI_TXFTLR  = 0x18
let SPI_RXFTLR  = 0x1C
let SPI_TXFLR   = 0x20
let SPI_RXFLR   = 0x24
let SPI_SR      = 0x28
let SPI_DR      = 0x60

## Status register bits
let SPI_SR_BUSY    = (1 << 0)
let SPI_SR_TFNF    = (1 << 1)   ## TX FIFO not full
let SPI_SR_TFE     = (1 << 2)   ## TX FIFO empty
let SPI_SR_RFNE    = (1 << 3)   ## RX FIFO not empty
let SPI_SR_RFF     = (1 << 4)   ## RX FIFO full

## --- SPI Master API ---

proc spi_init(base, mode, speed_hz, data_bits):
    ## Disable controller
    mem_write(base + SPI_ENABLE, 0, 4)
    
    ## CTRLR0 configuration:
    ##   bits[15:0] — data frame size (data_bits - 1)
    ##   bits[21:16] — SPI frame format (0 = Motorola)
    ##   bits[23:22] — protocol (0 = standard SPI)
    ##   bits[25:24] — clock polarity/phase (mode & 3)
    let ctrlr0 = (data_bits - 1) & 0xFFFF
    let spi_mode = mode & 3
    
    ## CPOL = mode bit 1, CPHA = mode bit 0
    if (spi_mode & 1) != 0:
        ctrlr0 = ctrlr0 | (1 << 6)   ## SCPH
    if (spi_mode & 2) != 0:
        ctrlr0 = ctrlr0 | (1 << 7)   ## SCPOL
    
    mem_write(base + SPI_CTRLR0, ctrlr0, 4)
    
    ## Baud rate: input_clock / (BAUDR + 1)
    ## For 100 MHz input, BAUDR = 9 -> 10 MHz SPI clock
    let baudr = 9
    mem_write(base + SPI_BAUDR, baudr, 4)
    
    ## TX FIFO threshold = 0 (interrupt when empty)
    mem_write(base + SPI_TXFTLR, 0, 4)
    ## RX FIFO threshold = 0 (interrupt when 1+ bytes)
    mem_write(base + SPI_RXFTLR, 0, 4)
    
    ## Enable controller
    mem_write(base + SPI_ENABLE, 1, 4)

proc spi_cs_enable(base, cs_num):
    let ser = mem_read(base + SPI_SER, 4)
    mem_write(base + SPI_SER, ser | (1 << cs_num), 4)

proc spi_cs_disable(base, cs_num):
    let ser = mem_read(base + SPI_SER, 4)
    mem_write(base + SPI_SER, ser & ~(1 << cs_num), 4)

proc spi_transfer_byte(base, tx_byte):
    ## Set frame count to 1
    mem_write(base + SPI_CTRLR1, 0, 4)
    
    ## Wait for TX FIFO not full
    while (mem_read(base + SPI_SR, 4) & SPI_SR_TFNF) == 0:
        pass
    
    ## Write data to TX FIFO
    mem_write(base + SPI_DR, tx_byte & 0xFF, 4)
    
    ## Wait for RX FIFO not empty (transfer complete)
    while (mem_read(base + SPI_SR, 4) & SPI_SR_RFNE) == 0:
        pass
    
    ## Read received data
    return mem_read(base + SPI_DR, 4) & 0xFF

proc spi_transfer(base, tx_data, length):
    ## Set frame count
    mem_write(base + SPI_CTRLR1, length - 1, 4)
    
    let rx_data = array(length)
    let tx_pos = 0
    let rx_pos = 0
    
    while rx_pos < length:
        ## Fill TX FIFO
        while (mem_read(base + SPI_SR, 4) & SPI_SR_TFNF) != 0 and tx_pos < length:
            mem_write(base + SPI_DR, tx_data[tx_pos] & 0xFF, 4)
            tx_pos = tx_pos + 1
        
        ## Read RX FIFO
        while (mem_read(base + SPI_SR, 4) & SPI_SR_RFNE) != 0 and rx_pos < length:
            rx_data[rx_pos] = mem_read(base + SPI_DR, 4) & 0xFF
            rx_pos = rx_pos + 1
    
    return rx_data

proc spi_write(base, tx_data, length):
    ## Write-only: discard received data
    let dummy = spi_transfer(base, tx_data, length)

proc spi_read(base, length):
    ## Read-only: send zeros as TX data
    let tx_buf = array(length)
    let i = 0
    while i < length:
        tx_buf[i] = 0
        i = i + 1
    return spi_transfer(base, tx_buf, length)

## --- Convenience: write then read (common pattern for SPI devices) ---

proc spi_write_read(base, tx_data, tx_len, rx_len):
    ## Send command bytes then read response
    ## Must handle CS manually with cs_enable/disable before/after
    let tx_buf = array(tx_len + rx_len)
    let i = 0
    while i < tx_len:
        tx_buf[i] = tx_data[i]
        i = i + 1
    while i < (tx_len + rx_len):
        tx_buf[i] = 0
        i = i + 1
    
    let result = spi_transfer(base, tx_buf, tx_len + rx_len)
    return result
