## drivers/gpio.sage — Pure-Sage GPIO Driver for SG2002 / DesignWare GPIO
##
## Supports up to 4 GPIO banks (32 pins each) on the Sophgo SG2002.
## Uses DesignWare APB GPIO controller registers.
##
## Register map (per bank, relative to base):
##   0x00 — SWPORT_DR      Data register (read/write pin state)
##   0x04 — SWPORT_DDR     Data direction (1=output, 0=input)
##   0x50 — INTEN          Interrupt enable
##   0x54 — INTMASK        Interrupt mask
##   0x58 — INTTYPE_LEVEL  Interrupt type (1=level, 0=edge)
##   0x5C — INT_POLARITY   Interrupt polarity (1=high/rising, 0=low/falling)
##   0x60 — INTSTATUS      Interrupt status (read to clear)
##   0x64 — RAW_INTSTATUS  Raw interrupt status
##   0x40 — PORTA_EOI      End of interrupt (write 1 to clear)

## GPIO bank base addresses (SG2002)
let GPIO0_BASE = 0x03020000
let GPIO1_BASE = 0x03021000
let GPIO2_BASE = 0x03022000
let GPIO3_BASE = 0x03023000

## Register offsets
let GPIO_DR    = 0x00    ## Data register
let GPIO_DDR   = 0x04    ## Data direction register
let GPIO_EOI   = 0x40    ## End of interrupt
let GPIO_INTEN = 0x50    ## Interrupt enable

## --- GPIO Pin API ---

proc gpio_set_mode(bank_base, pin, mode):
    ## mode: 0 = input, 1 = output
    let ddr = mem_read(bank_base + GPIO_DDR, 4)
    if mode == 1:
        ddr = ddr | (1 << pin)
    else:
        ddr = ddr & ~(1 << pin)
    mem_write(bank_base + GPIO_DDR, ddr, 4)

proc gpio_write(bank_base, pin, value):
    ## value: 0 = low, 1 = high
    let data = mem_read(bank_base + GPIO_DR, 4)
    if value == 1:
        data = data | (1 << pin)
    else:
        data = data & ~(1 << pin)
    mem_write(bank_base + GPIO_DR, data, 4)

proc gpio_read(bank_base, pin):
    let data = mem_read(bank_base + GPIO_DR, 4)
    if (data & (1 << pin)) != 0:
        return 1
    return 0

proc gpio_toggle(bank_base, pin):
    let data = mem_read(bank_base + GPIO_DR, 4)
    data = data ^ (1 << pin)
    mem_write(bank_base + GPIO_DR, data, 4)

## --- Bank-level API ---

proc gpio_write_port(bank_base, value):
    mem_write(bank_base + GPIO_DR, value, 4)

proc gpio_read_port(bank_base):
    return mem_read(bank_base + GPIO_DR, 4)

proc gpio_set_direction_port(bank_base, mask_output):
    mem_write(bank_base + GPIO_DDR, mask_output, 4)

## --- Interrupt API ---

proc gpio_enable_interrupt(bank_base, pin):
    let ien = mem_read(bank_base + GPIO_INTEN, 4)
    mem_write(bank_base + GPIO_INTEN, ien | (1 << pin), 4)

proc gpio_disable_interrupt(bank_base, pin):
    let ien = mem_read(bank_base + GPIO_INTEN, 4)
    mem_write(bank_base + GPIO_INTEN, ien & ~(1 << pin), 4)

proc gpio_clear_interrupt(bank_base, pin):
    ## Write 1 to EOI to clear interrupt for the pin
    mem_write(bank_base + GPIO_EOI, (1 << pin), 4)

## --- Convenience helpers ---

proc gpio_init_output(bank_base, pin, initial_value):
    gpio_write(bank_base, pin, initial_value)
    gpio_set_mode(bank_base, pin, 1)

proc gpio_init_input(bank_base, pin):
    gpio_set_mode(bank_base, pin, 0)

## Onboard LED (LicheeRV Nano: GPIO0, pin 14 — active low)
proc led_init():
    gpio_init_output(GPIO0_BASE, 14, 1)

proc led_on():
    gpio_write(GPIO0_BASE, 14, 0)

proc led_off():
    gpio_write(GPIO0_BASE, 14, 1)

proc led_toggle():
    gpio_toggle(GPIO0_BASE, 14)
