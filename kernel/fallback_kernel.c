/* kernel/fallback_kernel.c
 *
 * SageOS-RV kernel entry point (C layer).
 *
 * Architecture:
 *   1. UART 16550A init
 *   2. Wire uart_putc / uart_getchar directly into MetalVM.write_char /
 *      MetalVM.read_char (fields on the struct -- no config wrapper)
 *   3. metal_vm_init(&sage_vm)
 *   4. metal_vm_load_binary(&sage_vm, blob, size)
 *   5. metal_vm_run(&sage_vm)   <- executes kmain.sgvm
 *
 * Compile flags (enforced by sagemake):
 *   -march=rv64imac_zicsr_zifencei -mabi=lp64
 *   -nostdlib -ffreestanding -O2
 *   -DSAGE_BARE_METAL -DSAGE_METAL_VM
 */

#include <stdint.h>
#include <stddef.h>
#include "metal_vm.h"
#include "metal_rv64_vm.h"

/* --------------------------------------------------------------------------
 * UART 16550A  (QEMU virt / LicheeRV Nano base address)
 * -------------------------------------------------------------------------- */
#define UART_BASE  0x10000000UL
#define UART_THR   0   /* Transmit Holding Register  (write) */
#define UART_RBR   0   /* Receive Buffer Register    (read)  */
#define UART_IER   1
#define UART_FCR   2
#define UART_LCR   3
#define UART_LSR   5
#define UART_THRE  0x20
#define UART_DR    0x01

static inline void    _w8(uint64_t a, uint8_t v) { *(volatile uint8_t *)a = v; }
static inline uint8_t _r8(uint64_t a)            { return *(volatile uint8_t *)a; }

static void uart_init(void) {
    _w8(UART_BASE + UART_IER, 0x00);
    _w8(UART_BASE + UART_FCR, 0xC7);
    _w8(UART_BASE + UART_LCR, 0x03);
}

static void uart_putc(char c) {
    while ((_r8(UART_BASE + UART_LSR) & UART_THRE) == 0);
    _w8(UART_BASE + UART_THR, (uint8_t)c);
}

static int uart_getchar(void) {
    if (_r8(UART_BASE + UART_LSR) & UART_DR)
        return (int)_r8(UART_BASE + UART_RBR);
    return -1;
}

static void uart_puts(const char *s) {
    while (*s) uart_putc(*s++);
}

/* --------------------------------------------------------------------------
 * Linker symbols -- injected by objcopy for both .sgvm blobs
 *
 *   kmain.sgvm  -> .sgvm_kernel -> _binary_kernel_kmain_sgvm_start/end
 *   shell.sgvm  -> .sgvm_shell  -> _binary_shell_shell_sgvm_start/end
 * -------------------------------------------------------------------------- */
extern const uint8_t _binary_kernel_kmain_sgvm_start[];
extern const uint8_t _binary_kernel_kmain_sgvm_end[];
extern const uint8_t _binary_shell_shell_sgvm_start[];
extern const uint8_t _binary_shell_shell_sgvm_end[];

/* --------------------------------------------------------------------------
 * Static MetalVM instance  (zero dynamic allocation)
 * -------------------------------------------------------------------------- */
static MetalVM sage_vm;

/* --------------------------------------------------------------------------
 * Halt
 * -------------------------------------------------------------------------- */
static void _halt(const char *reason) __attribute__((noreturn));
static void _halt(const char *reason) {
    uart_puts("\n[FATAL] ");
    uart_puts(reason);
    uart_puts("\n[FATAL] System halted. Reset to recover.\n");
    for (;;) __asm__ volatile("wfi");
}

/* --------------------------------------------------------------------------
 * kmain -- called from boot.S
 * -------------------------------------------------------------------------- */
void kmain(uint64_t hart_id, uint64_t dtb_addr) {
    (void)hart_id;
    (void)dtb_addr;

    uart_init();
    uart_puts("[MetalVM] Initializing...\n");

    /* Zero + init VM state */
    metal_vm_init(&sage_vm);

    /* Wire I/O callbacks directly -- fields on MetalVM struct */
    sage_vm.write_char = uart_putc;
    sage_vm.read_char  = uart_getchar;

    /* Validate kernel blob */
    const uint8_t *kblob = _binary_kernel_kmain_sgvm_start;
    int            ksz   = (int)(_binary_kernel_kmain_sgvm_end - kblob);

    if (ksz <= 0)
        _halt("kmain.sgvm blob is empty -- rebuild with ./sagemake build");

    uart_puts("[MetalVM] Loading kmain.sgvm...\n");

    int load_ok = metal_vm_load_binary(&sage_vm, kblob, ksz);
    if (load_ok != 0)
        _halt("metal_vm_load_binary() failed");

    uart_puts("[MetalVM] Running kernel...\n");

    int rc = metal_vm_run(&sage_vm);

    /* Should never reach here */
    if (rc != 0) {
        uart_puts("[MetalVM] kmain.sgvm exited with error\n");
        if (sage_vm.error_msg) uart_puts(sage_vm.error_msg);
    } else {
        uart_puts("[MetalVM] kmain.sgvm returned (unexpected)\n");
    }

    _halt("Kernel returned from MetalVM");
}
