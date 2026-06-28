/* kernel/metal_vm_glue.c — SageOS-RV bare-metal MetalVM integration
 *
 * Wires SageLang's freestanding MetalVM into the SageOS-RV kernel.
 * No libc, no malloc — all pools are static inside MetalVM.
 *
 * Compile with: -ffreestanding -nostdlib -DSAGE_BARE_METAL -DSAGE_METAL_VM
 */

#define SAGE_BARE_METAL 1
#define SAGE_METAL_VM   1

#include <stdint.h>
#include "metal_vm.h"
#include "metal_rv64_vm.h"

/* Forward declaration — provided by the kernel's UART driver */
extern void uart_putc(char c);
extern int  uart_getchar(void);

/* Single static VM instance — no heap allocation */
static MetalVM sage_vm;

/* ---------------------------------------------------------------------------
 * I/O callbacks — bridge MetalVM I/O to the kernel UART
 * -------------------------------------------------------------------------*/

static void metal_write_char(char c) {
    if (c == '\n')
        uart_putc('\r');
    uart_putc(c);
}

static int metal_read_char(void) {
    return uart_getchar();
}

/* ---------------------------------------------------------------------------
 * Public API
 * -------------------------------------------------------------------------*/

/**
 * sage_metal_vm_init() — zero-initialise the VM and attach I/O callbacks.
 * Call once from sage_kernel_main() before running any bytecode.
 */
void sage_metal_vm_init(void) {
    metal_vm_init(&sage_vm);
    sage_vm.write_char  = metal_write_char;
    sage_vm.read_char   = metal_read_char;
    sage_vm.write_port  = (void*)0;   /* Not used on RISC-V */
    sage_vm.read_port   = (void*)0;
    sage_vm.map_mmio    = (void*)0;
}

/**
 * sage_metal_vm_get() — return a pointer to the kernel-owned MetalVM.
 * Use this to load bytecode and call metal_vm_run() from the kernel.
 */
MetalVM *sage_metal_vm_get(void) {
    return &sage_vm;
}

/**
 * sage_metal_vm_exec() — convenience: load + run a bytecode buffer.
 * Returns 0 on clean halt, non-zero on error.
 */
int sage_metal_vm_exec(const unsigned char *bytecode, int length) {
    metal_vm_init(&sage_vm);           /* reset for a fresh run */
    sage_vm.write_char = metal_write_char;
    sage_vm.read_char  = metal_read_char;
    metal_vm_load(&sage_vm, bytecode, length);
    if (!metal_vm_verify(&sage_vm))
        return -1;
    return metal_vm_run(&sage_vm);
}
