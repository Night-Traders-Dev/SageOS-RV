## drivers/plic.sage — Pure-Sage PLIC Driver for RISC-V
##
## Platform-Level Interrupt Controller (PLIC) driver.
## Used on both QEMU virt and LicheeRV Nano (SG2002).
##
## PLIC register layout (relative to base):
##   0x000000 — Source priority registers (1024 sources, 4 bytes each)
##   0x001000 — Pending bits (32 words of 32 bits = 1024 sources)
##   0x002000 — Enable bits per context (1024 sources)
##   0x200000 — Threshold per context
##   0x200004 — Claim/complete per context
##
## PLIC context layout:
##   Machine mode:  context 0
##   Supervisor mode: context 1

## PLIC base addresses
let PLIC_BASE_QEMU = 0x0C000000
let PLIC_BASE_SG2002 = 0x0C000000   ## Same on SG2002

## Register offsets (relative to PLIC base)
let PLIC_PRIORITY_OFFSET    = 0x000000
let PLIC_PENDING_OFFSET     = 0x001000
let PLIC_ENABLE_OFFSET      = 0x002000
let PLIC_ENABLE_STRIDE      = 0x080    ## 32 words * 4 bytes = 0x80 bytes per context
let PLIC_CONTEXT_OFFSET     = 0x200000
let PLIC_CONTEXT_STRIDE     = 0x1000   ## 4K per context

## PLIC context sub-registers
let PLIC_THRESHOLD          = 0x00
let PLIC_CLAIM              = 0x04

## Interrupt source IDs (SG2002)
let IRQ_UART0    = 10
let IRQ_UART1    = 11
let IRQ_I2C0     = 22
let IRQ_I2C1     = 23
let IRQ_SPI0     = 16
let IRQ_GPIO0    = 44
let IRQ_GPIO1    = 45
let IRQ_WDT      = 1
let IRQ_TIMER    = 5

## --- PLIC API ---

proc plic_init(base):
    let plic = base
    ## Disable all interrupts for S-mode context (context 1)
    let i = 0
    let s_enable_base = plic + PLIC_ENABLE_OFFSET + (1 * PLIC_ENABLE_STRIDE)
    while i < 32:
        mem_write(s_enable_base + (i * 4), 0, 4)
        i = i + 1
    
    ## Set S-mode threshold to 0 (accept all priorities)
    let s_context_base = plic + PLIC_CONTEXT_OFFSET + (1 * PLIC_CONTEXT_STRIDE)
    mem_write(s_context_base + PLIC_THRESHOLD, 0, 4)

proc plic_set_priority(base, irq_id, priority):
    ## priority: 0 = disabled, 1-7 = enabled
    mem_write(base + PLIC_PRIORITY_OFFSET + (irq_id * 4), priority & 0x7, 4)

proc plic_enable_interrupt(base, irq_id):
    ## Enable for S-mode context (context 1)
    let word_idx = irq_id / 32
    let bit_idx = irq_id % 32
    let s_enable_base = base + PLIC_ENABLE_OFFSET + (1 * PLIC_ENABLE_STRIDE)
    let reg = mem_read(s_enable_base + (word_idx * 4), 4)
    mem_write(s_enable_base + (word_idx * 4), reg | (1 << bit_idx), 4)

proc plic_disable_interrupt(base, irq_id):
    let word_idx = irq_id / 32
    let bit_idx = irq_id % 32
    let s_enable_base = base + PLIC_ENABLE_OFFSET + (1 * PLIC_ENABLE_STRIDE)
    let reg = mem_read(s_enable_base + (word_idx * 4), 4)
    mem_write(s_enable_base + (word_idx * 4), reg & ~(1 << bit_idx), 4)

proc plic_claim(base):
    ## Claim the highest-priority pending interrupt for S-mode
    let s_context_base = base + PLIC_CONTEXT_OFFSET + (1 * PLIC_CONTEXT_STRIDE)
    return mem_read(s_context_base + PLIC_CLAIM, 4)

proc plic_complete(base, irq_id):
    ## Mark interrupt as complete for S-mode
    let s_context_base = base + PLIC_CONTEXT_OFFSET + (1 * PLIC_CONTEXT_STRIDE)
    mem_write(s_context_base + PLIC_CLAIM, irq_id, 4)

## --- Convenience: set up a handler chain ---

proc plic_enable_uart(base):
    plic_set_priority(base, IRQ_UART0, 7)
    plic_enable_interrupt(base, IRQ_UART0)

proc plic_enable_timer(base):
    plic_set_priority(base, IRQ_TIMER, 7)
    plic_enable_interrupt(base, IRQ_TIMER)

proc plic_enable_gpio(base):
    plic_set_priority(base, IRQ_GPIO0, 5)
    plic_enable_interrupt(base, IRQ_GPIO0)
