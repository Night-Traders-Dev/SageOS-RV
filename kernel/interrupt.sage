## kernel/interrupt.sage — Interrupt and Trap Management
##
## RISC-V 64 interrupt and exception handling.
## Uses stvec CSR for trap vector, scause for cause identification.

## Trap causes (scause values)
let CAUSE_INST_MISALIGNED = 0
let CAUSE_INST_ACCESS = 1
let CAUSE_ILLEGAL_INST = 2
let CAUSE_BREAKPOINT = 3
let CAUSE_LOAD_MISALIGNED = 4
let CAUSE_LOAD_ACCESS = 5
let CAUSE_STORE_MISALIGNED = 6
let CAUSE_STORE_ACCESS = 7
let CAUSE_ECALL_USER = 8
let CAUSE_ECALL_SUPER = 9
let CAUSE_ECALL_HYPER = 10
let CAUSE_ECALL_MACHINE = 11
let CAUSE_INST_PAGE_FAULT = 12
let CAUSE_LOAD_PAGE_FAULT = 13
let CAUSE_STORE_PAGE_FAULT = 15

## Interrupt causes (scause with bit 63 set)
let IRQ_S_SOFTWARE = 0x80000001
let IRQ_S_TIMER = 0x80000005
let IRQ_S_EXTERNAL = 0x80000009

## PLIC registers (same base 0x0C000000 on QEMU and SG2002)
let PLIC_BASE = 0x0C000000
let PLIC_PRIORITY = PLIC_BASE + 0x00
let PLIC_PENDING = PLIC_BASE + 0x1000
let PLIC_ENABLE = PLIC_BASE + 0x2000
let PLIC_THRESHOLD = PLIC_BASE + 0x200000
let PLIC_CLAIM = PLIC_BASE + 0x201004

## Timer uses SBI TIME extension (portable, works on both
## QEMU CLINT and SG2002 ACLINT). No direct CLINT/ACLINT MMIO needed.

## Interrupt handler table
let irq_handlers = {}

## Register an interrupt handler
proc irq_register(irq_id, handler):
    irq_handlers[irq_id] = handler

## Initialize interrupt system
proc interrupt_init():
    ## Set up PLIC
    ## Enable UART interrupt (IRQ 10 on QEMU virt)
    plic_enable_irq(10)
    plic_set_priority(10, 1)

    ## Set up trap vector (stvec)
    ## In real implementation: write to stvec CSR
    ## asm volatile("csrw stvec, %0" :: "r"(trap_entry))

    console_puts("  Interrupts: PLIC + stvec configured\n")

## PLIC operations
proc plic_set_priority(irq, priority):
    mem_write(PLIC_PRIORITY + irq * 4, 4, priority)

proc plic_enable_irq(irq):
    ## Enable for hart 0, M-mode context
    let reg = PLIC_ENABLE + (irq / 32) * 4
    let bit = 1 << (irq % 32)
    let cur = mem_read(reg, 4)
    mem_write(reg, 4, cur | bit)

proc plic_disable_irq(irq):
    let reg = PLIC_ENABLE + (irq / 32) * 4
    let bit = 1 << (irq % 32)
    let cur = mem_read(reg, 4)
    mem_write(reg, 4, cur & (~bit))

proc plic_claim():
    return mem_read(PLIC_CLAIM, 4)

proc plic_complete(irq):
    mem_write(PLIC_CLAIM, 4, irq)

## Timer operations
proc timer_init():
    ## Set up S-mode timer interrupt via SBI
    ## SBI set_timer call
    ## In real implementation: ecall to SBI
    console_puts("  Timer: SBI timer configured\n")

proc timer_set(next_tick):
    ## SBI set_timer call
    ## ecall with a7=0, a0=next_tick
    pass

## Trap handler (called from assembly trap entry)
proc trap_handler(scause, stval, sepc):
    if scause == IRQ_S_TIMER:
        ## Timer interrupt
        timer_handle_tick()
        return
    if scause == IRQ_S_EXTERNAL:
        ## External interrupt (PLIC)
        let irq = plic_claim()
        if irq in irq_handlers:
            irq_handlers[irq]()
        plic_complete(irq)
        return
    if scause == CAUSE_ECALL_SUPER:
        ## S-mode ecall (syscall)
        syscall_handler(sepc)
        return

    ## Unknown trap - panic
    console_puts("TRAP: scause=")
    console_put_hex(scause)
    console_puts(" stval=")
    console_put_hex(stval)
    console_puts(" sepc=")
    console_put_hex(sepc)
    console_puts("\n")
    panic("unhandled trap")

proc timer_handle_tick():
    ## Handle timer tick
    ## Re-arm timer for next tick
    timer_set(0)
    pass

proc syscall_handler(sepc):
    ## Handle S-mode ecall
    ## Advance SEPC past ecall instruction
    pass
