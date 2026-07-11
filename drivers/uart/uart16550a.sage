## drivers/uart16550a.sage — Pure-Sage 16550A UART Driver
##
## Works on any board with a 16550A-compatible UART controller.
## Used by: QEMU virt, LicheeRV Nano (SG2002), and other RISC-V boards.
##
## Registers (byte offsets):
##   0 — THR/RBR  (Transmit / Receive Buffer)
##   1 — IER      (Interrupt Enable Register)
##   2 — FCR      (FIFO Control Register)
##   3 — LCR      (Line Control Register)
##   5 — LSR      (Line Status Register)
##
## Usage:
##   uart_init(base_addr)     — Initialize UART at given MMIO base
##   uart_putc(base_addr, c)  — Write character (blocks until THRE)
##   uart_getc(base_addr)     — Read character (returns -1 if no data)
##   uart_puts(base_addr, s)  — Write null-terminated string

## UART register offsets
let UART_THR  = 0   ## Transmit Holding Register (write)
let UART_RBR  = 0   ## Receive Buffer Register (read)
let UART_IER  = 1   ## Interrupt Enable Register
let UART_FCR  = 2   ## FIFO Control Register
let UART_LCR  = 3   ## Line Control Register
let UART_MCR  = 4   ## Modem Control Register
let UART_LSR  = 5   ## Line Status Register
let UART_MSR  = 6   ## Modem Status Register

## LSR bit flags
let LSR_DR    = 0x01   ## Data Ready
let LSR_THRE  = 0x20   ## Transmitter Holding Register Empty

## Stride and Width for SG2002 compatibility
## (In a real system, these would be struct fields. Using globals for simplicity)
let uart_stride = 0
let uart_wsize = 1

## --- Driver API ---

proc uart_set_stride(stride, width):
    uart_stride = stride
    uart_wsize = width

proc uart_init(base):
    ## Disable interrupts
    mem_write(base + (UART_IER << uart_stride), 0, uart_wsize)
    ## Enable FIFO, clear buffers, 14-byte threshold
    mem_write(base + (UART_FCR << uart_stride), 0xC7, uart_wsize)
    ## 8N1 mode (8 data bits, no parity, 1 stop bit)
    mem_write(base + (UART_LCR << uart_stride), 0x03, uart_wsize)

proc uart_putc(base, ch):
    ## Wait for transmitter holding register to be empty
    while (mem_read(base + (UART_LSR << uart_stride), uart_wsize) & LSR_THRE) == 0:
        pass
    ## Write the character
    mem_write(base + (UART_THR << uart_stride), ch, uart_wsize)

proc uart_getc(base):
    ## Check if data is available
    if (mem_read(base + (UART_LSR << uart_stride), uart_wsize) & LSR_DR) == 0:
        return -1
    ## Read the received character
    return mem_read(base + (UART_RBR << uart_stride), uart_wsize) & 0xFF

proc uart_puts(base, s):
    ## Write each character of the string
    let i = 0
    let slen = len(s)
    while i < slen:
        uart_putc(base, char_code(s, i))
        i = i + 1

## --- Helper: get character code from string at index ---
proc char_code(s, idx):
    ## SRVM provides this via bytecode; placeholder for compilation
    ## In practice, string indexing is handled by the VM
    return 0

## --- Print a decimal number ---
proc uart_put_dec(base, n):
    if n == 0:
        uart_putc(base, 48)
        return
    let buf = array(32)
    let pos = 0
    if n < 0:
        uart_putc(base, 45)
        n = -n
    while n > 0:
        buf[pos] = 48 + (n % 10)
        n = n / 10
        pos = pos + 1
    while pos > 0:
        pos = pos - 1
        uart_putc(base, buf[pos])

## --- Print hex number ---
proc uart_put_hex(base, n):
    let hex_chars = "0123456789ABCDEF"
    let buf = array(16)
    let pos = 0
    if n == 0:
        uart_puts(base, "0x0")
        return
    uart_puts(base, "0x")
    while n > 0:
        let digit = n & 0xF
        buf[pos] = char_code(hex_chars, digit)
        n = n >> 4
        pos = pos + 1
    while pos > 0:
        pos = pos - 1
        uart_putc(base, buf[pos])
