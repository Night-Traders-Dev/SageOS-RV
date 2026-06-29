## boot/arch/rv64/boot.S — RISC-V 64 boot assembly for SageOS
## Entry point after OpenSBI hands off in S-mode.
##
## Board configuration passed via GCC defines:
##   UART_BASE        — 16550A UART MMIO base address
##   CONFIG_STACK_TOP — Initial stack pointer address
##   CONFIG_MEM_BASE  — DRAM base address

#include "sbi.h"

#ifndef UART_BASE
#  define UART_BASE  0x10000000
#endif
#ifndef CONFIG_STACK_TOP
#  define CONFIG_STACK_TOP  0x81000000
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

    ## Set up stack pointer from board configuration
    li   sp, CONFIG_STACK_TOP

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
    call sage_kernel_main

    ## Halt
6:
    wfi
    j    6b
