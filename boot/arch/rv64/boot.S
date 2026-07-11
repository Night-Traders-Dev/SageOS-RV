## boot/arch/rv64/boot.S — RISC-V 64 boot assembly for SageOS
## Entry point after OpenSBI hands off in S-mode.
##
## Board configuration passed via GCC defines:
##   UART_BASE        — 16550A UART MMIO base address
##   CONFIG_MEM_BASE  — DRAM base address
##
## Stack pointer comes from linker symbol _stack_top (linker.ld).

#include "sbi.h"

#ifndef UART_BASE
#  define UART_BASE  0x10000000
#endif

    .section .text.boot
    .globl _start

_start:
    ## Save hart_id (a0) and dtb_addr (a1) from OpenSBI S-mode entry
    mv   s0, a0
    mv   s1, a1

    ## Disable MMU — ensure satp = 0 so we run with physical addresses
    csrw satp, zero
    sfence.vma

    ## Set up stack pointer from linker symbol (single source of truth)
    la   sp, _stack_top

    ## Output 'S' to prove we're running, using SBI ecall
    li   a7, SBI_CONSOLE_PUTCHAR
    li   a0, 0x53            ## 'S'
    ecall

    ## Output 'B' (SageBoot marker)
    li   a0, 0x42            ## 'B'
    ecall

    ## Output 'I' (SBI init done)
    li   a0, 0x49            ## 'I'
    ecall

    ## Initialize UART (16550A) for direct kernel access
    li   t0, UART_BASE       ## UART base (board-specific)
    sb   zero, 1(t0)         ## IER = 0 (disable interrupts)
    li   t1, 0x03
    sb   t1, 3(t0)           ## LCR = 0x03 (8N1, DLAB=0)
    li   t1, 0xC7
    sb   t1, 2(t0)           ## FCR = 0xC7 (enable FIFO, clear, 14-byte threshold)

    ## Verify UART by polling THRE (should be 1 after init)
    li   t2, 0x20            ## THRE bit mask
1:
    lbu  t3, 5(t0)           ## Read LSR (byte access)
    and  t3, t3, t2
    beqz t3, 1b

    ## Output 'K' via direct UART to confirm init works
    li   t1, 0x4B            ## 'K'
    sb   t1, 0(t0)           ## Write THR (byte access)

    ## Wait for THR empty
2:
    lbu  t3, 5(t0)
    and  t3, t3, t2
    beqz t3, 2b

    ## Output '!' 
    li   t1, 0x21            ## '!'
    sb   t1, 0(t0)

3:
    lbu  t3, 5(t0)
    and  t3, t3, t2
    beqz t3, 3b

    ## Output newline
    li   t1, 0x0A            ## '\n'
    sb   t1, 0(t0)

    ## Clear BSS
    la   t0, _bss_start
    la   t1, _bss_end
4:
    bgeu t0, t1, 5f
    sd   zero, 0(t0)
    addi t0, t0, 8
    j    4b
5:
    ## Restore hart_id and dtb_addr, then call kernel main
    mv   a0, s0
    mv   a1, s1
    li   a2, 0       ## No SageBoot handoff struct in bare-metal fallback mode
    call sage_kernel_main

    ## Halt
6:
    wfi
    j    6b

    .align 4
    .globl trap_vector
trap_vector:
    # Save 31 general purpose registers (except zero) + sepc = 32 * 8 = 256 bytes
    addi sp, sp, -256
    sd ra,   1*8(sp)
    # sp is 2*8(sp), saved differently
    sd gp,   3*8(sp)
    sd tp,   4*8(sp)
    sd t0,   5*8(sp)
    sd t1,   6*8(sp)
    sd t2,   7*8(sp)
    sd s0,   8*8(sp)
    sd s1,   9*8(sp)
    sd a0,  10*8(sp)
    sd a1,  11*8(sp)
    sd a2,  12*8(sp)
    sd a3,  13*8(sp)
    sd a4,  14*8(sp)
    sd a5,  15*8(sp)
    sd a6,  16*8(sp)
    sd a7,  17*8(sp)
    sd s2,  18*8(sp)
    sd s3,  19*8(sp)
    sd s4,  20*8(sp)
    sd s5,  21*8(sp)
    sd s6,  22*8(sp)
    sd s7,  23*8(sp)
    sd s8,  24*8(sp)
    sd s9,  25*8(sp)
    sd s10, 26*8(sp)
    sd s11, 27*8(sp)
    sd t3,  28*8(sp)
    sd t4,  29*8(sp)
    sd t5,  30*8(sp)
    sd t6,  31*8(sp)
    
    csrr t0, sepc
    sd t0, 0*8(sp)

    # C trap handler (args: sp, scause, stval)
    mv a0, sp
    csrr a1, scause
    csrr a2, stval
    call trap_handler_c

    # Restore sepc
    ld t0, 0*8(sp)
    csrw sepc, t0

    # Restore all registers
    ld ra,   1*8(sp)
    ld gp,   3*8(sp)
    ld tp,   4*8(sp)
    ld t0,   5*8(sp)
    ld t1,   6*8(sp)
    ld t2,   7*8(sp)
    ld s0,   8*8(sp)
    ld s1,   9*8(sp)
    ld a0,  10*8(sp)
    ld a1,  11*8(sp)
    ld a2,  12*8(sp)
    ld a3,  13*8(sp)
    ld a4,  14*8(sp)
    ld a5,  15*8(sp)
    ld a6,  16*8(sp)
    ld a7,  17*8(sp)
    ld s2,  18*8(sp)
    ld s3,  19*8(sp)
    ld s4,  20*8(sp)
    ld s5,  21*8(sp)
    ld s6,  22*8(sp)
    ld s7,  23*8(sp)
    ld s8,  24*8(sp)
    ld s9,  25*8(sp)
    ld s10, 26*8(sp)
    ld s11, 27*8(sp)
    ld t3,  28*8(sp)
    ld t4,  29*8(sp)
    ld t5,  30*8(sp)
    ld t6,  31*8(sp)
    addi sp, sp, 256
    sret
