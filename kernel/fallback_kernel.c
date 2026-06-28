/* kernel/fallback_kernel.c
 *
 * SageOS-RV kernel entry point (C layer).
 *
 * This IS the kernel.  There is no C transpiler step.
 *
 * Architecture:
 *   1. UART 16550A init
 *   2. Wire uart_putc / uart_getchar as MetalVM I/O callbacks
 *   3. metal_vm_init()  -- zero-alloc, uses static MetalVM instance
 *   4. metal_vm_load_and_run(_kernel_sgvm_start, kernel_size)
 *        -> executes kmain.sgvm (the Sage kernel)
 *   5. If MetalVM returns for any reason: UART banner + WFI halt
 *
 * POLICY:
 *   - No libc. No dynamic allocation. No fallback shell.
 *   - All fallible paths produce a visible UART message then halt.
 *   - The Sage layer (kmain.sage) owns all higher-level panic logic.
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
 * UART 16550A (QEMU virt / LicheeRV Nano)
 * -------------------------------------------------------------------------- */
#define UART_BASE   0x10000000UL
#define UART_THR    0   /* Transmit Holding Register  (write) */
#define UART_RBR    0   /* Receive Buffer Register    (read)  */
#define UART_IER    1   /* Interrupt Enable Register          */
#define UART_FCR    2   /* FIFO Control Register              */
#define UART_LCR    3   /* Line Control Register              */
#define UART_LSR    5   /* Line Status Register               */
#define UART_THRE   0x20
#define UART_DR     0x01

static inline void     _w8(uint64_t a, uint8_t v)  { *(volatile uint8_t *)a = v; }
static inline uint8_t  _r8(uint64_t a)             { return *(volatile uint8_t *)a; }

static void uart_init(void) {
    _w8(UART_BASE + UART_IER, 0x00);  /* disable interrupts        */
    _w8(UART_BASE + UART_FCR, 0xC7);  /* enable + reset FIFOs      */
    _w8(UART_BASE + UART_LCR, 0x03);  /* 8N1, divisor latch off    */
}

void uart_putc(char c) {
    while ((_r8(UART_BASE + UART_LSR) & UART_THRE) == 0);
    _w8(UART_BASE + UART_THR, (uint8_t)c);
}

int uart_getchar(void) {
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
 * sagemake embeds:
 *   kmain.sgvm  -> .sgvm_kernel section -> _kernel_sgvm_start / _end
 *   shell.sgvm  -> .sgvm_shell  section -> _shell_sgvm_start  / _end
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
 * Halt  (called on any unrecoverable error before Sage is running)
 * -------------------------------------------------------------------------- */
static void _halt(const char *reason) __attribute__((noreturn));
static void _halt(const char *reason) {
    uart_puts("\n\n[FATAL] ");
    uart_puts(reason);
    uart_puts("\n[FATAL] System halted. Reset to recover.\n");
    for (;;) __asm__ volatile("wfi");
}

/* --------------------------------------------------------------------------
 * kmain -- called from boot.S after stack + BSS setup
 * -------------------------------------------------------------------------- */
void kmain(uint64_t hart_id, uint64_t dtb_addr) {
    (void)hart_id;
    (void)dtb_addr;

    uart_init();
    uart_puts("[MetalVM] Initializing...\n");

    /* Wire I/O callbacks: MetalVM uses these for Sage print/input */
    MetalVMConfig cfg = {
        .write_char = uart_putc,
        .read_char  = uart_getchar,
    };

    if (metal_vm_init(&sage_vm, &cfg) != METAL_VM_OK)
        _halt("metal_vm_init() failed");

    /* Validate kernel blob */
    const uint8_t *kblob  = _binary_kernel_kmain_sgvm_start;
    size_t         ksz    = (size_t)(_binary_kernel_kmain_sgvm_end - kblob);

    if (ksz == 0)
        _halt("kmain.sgvm blob is empty -- rebuild with ./sagemake build");

    uart_puts("[MetalVM] Loading kmain.sgvm (kernel)...\n");

    MetalVMStatus st = metal_vm_load_and_run(&sage_vm, kblob, ksz);

    /* Should never reach here -- kmain.sage loops or panics internally */
    if (st != METAL_VM_OK) {
        uart_puts("[MetalVM] kmain.sgvm exited with error\n");
    } else {
        uart_puts("[MetalVM] kmain.sgvm returned (unexpected)\n");
    }

    _halt("Kernel returned from MetalVM");
}
