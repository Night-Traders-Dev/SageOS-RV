/* kernel/fallback_kernel.c
 *
 * Minimal boot-glue trampoline for SageOS-RV.
 *
 * POLICY: This file contains NO fallback logic, NO built-in shell,
 * NO C-level feature substitutes.  Its only job is:
 *   1. Bring UART up so early boot messages work.
 *   2. Call sage_kernel_main() which is provided by the Sage -> C
 *      transpiler output (build/kernel.c) or by the MetalVM C layer.
 *
 * If sage_kernel_main() is missing or the Sage emit step failed,
 * the build MUST fail hard (see sagemake `fail` call) -- not silently
 * fall back to a C kernel.  This file will never be compiled as the
 * primary kernel; it only supplies the UART and trampoline symbols
 * that boot.S needs before jumping into Sage-land.
 *
 * There is NO shell here.  There are NO fallback paths.
 * Any missing Sage component triggers kernel_panic from Sage.
 */

#include <stdint.h>
#include "sbi.h"

/* 16550A UART ------------------------------------------------------------ */
#define UART_BASE  0x10000000UL
#define UART_THR   0
#define UART_LSR   5
#define UART_THRE  0x20

static inline void _mmio8_w(uint64_t a, uint8_t v)
    { *(volatile uint8_t *)a = v; }
static inline uint8_t _mmio8_r(uint64_t a)
    { return *(volatile uint8_t *)a; }

void uart_putc(char c) {
    while ((_mmio8_r(UART_BASE + UART_LSR) & UART_THRE) == 0);
    _mmio8_w(UART_BASE + UART_THR, (uint8_t)c);
}
int uart_getchar(void) {
    /* 0x01 = Data Ready */
    if (_mmio8_r(UART_BASE + UART_LSR) & 0x01)
        return _mmio8_r(UART_BASE + 0);
    return -1;
}

/* Trampoline ------------------------------------------------------------ */

/* Declared by build/kernel.c (Sage -> C transpiler output).
 * If the Sage emit step failed sagemake will abort before reaching link. */
extern void sage_kernel_main(uint64_t hart_id, uint64_t dtb_addr);

void sage_kernel_main_trampoline(uint64_t hart_id, uint64_t dtb_addr) {
    /* UART IER=0, FCR fifo enable, LCR 8N1 */
    _mmio8_w(UART_BASE + 1, 0x00);
    _mmio8_w(UART_BASE + 2, 0xC7);
    _mmio8_w(UART_BASE + 3, 0x03);
    sage_kernel_main(hart_id, dtb_addr);
    /* Unreachable: sage_kernel_main panics internally on any error. */
    while (1) __asm__ volatile("wfi");
}
