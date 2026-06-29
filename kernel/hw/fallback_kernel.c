/* kernel/fallback_kernel.c
 *
 * SageOS-RV kernel entry point (C layer).
 *
 * Entry symbol:  sage_kernel_main  (called from boot/arch/rv64/boot.S)
 *
 * Architecture:
 *   1. UART 16550A init
 *   2. PMM bump allocator init (used by vmm.c)
 *   3. Wire uart_putc / uart_getchar into MetalVM I/O callbacks
 *   4. metal_vm_init(&kernel_vm)
 *   5. metal_vm_load_binary(&kernel_vm, blob, size)
 *   6. metal_vm_run(&kernel_vm)   -- executes kmain.sgvm
 *
 * The kernel Sage code (kmain.sage) uses SRVM to load and run shell.sgvm.
 *
 * Compile flags (enforced by sagemake):
 *   -march=rv64imac_zicsr_zifencei -mabi=lp64
 *   -nostdlib -ffreestanding -O2
 *   -DSAGE_BARE_METAL -DSAGE_METAL_VM
 */

#include <stdint.h>
#include <stddef.h>
#include "metal_rv64_vm.h"

/* --------------------------------------------------------------------------
 * UART 16550A  (QEMU virt / LicheeRV Nano base address)
 * -------------------------------------------------------------------------- */
/* UART base — from build system (-DUART_BASE) or board default */
#ifndef UART_BASE
#define UART_BASE  0x10000000UL
#endif
#define UART_THR   0
#define UART_RBR   0
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
    // SBI legacy console_putchar (EID 0x01) — works reliably in QEMU
    register long a7 __asm__("a7") = 0x01;
    register long a0 __asm__("a0") = (long)(unsigned char)c;
    __asm__ volatile("ecall" : "+r"(a0) : "r"(a7) : "memory");
}

static int uart_getchar(void) {
    // SBI legacy console_getchar (EID 0x02) — returns char or -1
    register long a7 __asm__("a7") = 0x02;
    register long a0 __asm__("a0");
    __asm__ volatile("ecall" : "=r"(a0) : "r"(a7) : "memory");
    if (a0 >= 0 && a0 <= 255) return (int)a0;
    return -1;
}

static void uart_puts(const char *s) {
    while (*s) uart_putc(*s++);
}

/* --------------------------------------------------------------------------
 * PMM — simple bump allocator
 * -------------------------------------------------------------------------- */
#define PMM_PAGE_SIZE   4096UL
#define PMM_NUM_PAGES   256

static uint8_t  _pmm_arena[PMM_PAGE_SIZE * PMM_NUM_PAGES]
    __attribute__((aligned(PMM_PAGE_SIZE)));
static uint32_t _pmm_next = 0;

uint64_t pmm_alloc(void) {
    if (_pmm_next >= PMM_NUM_PAGES)
        return 0;
    uint64_t page = (uint64_t)(uintptr_t)&_pmm_arena[_pmm_next * PMM_PAGE_SIZE];
    _pmm_next++;
    uint64_t *p = (uint64_t *)(uintptr_t)page;
    for (size_t i = 0; i < PMM_PAGE_SIZE / sizeof(uint64_t); i++)
        p[i] = 0;
    return page;
}

/* --------------------------------------------------------------------------
 * Linker symbols — embedded .sgvm blobs
 * -------------------------------------------------------------------------- */
extern const uint8_t _binary_kernel_core_kmain_sgvm_start[];
extern const uint8_t _binary_kernel_core_kmain_sgvm_end[];
extern const uint8_t _binary_shell_shell_sgvm_start[];
extern const uint8_t _binary_shell_shell_sgvm_end[];

/* --------------------------------------------------------------------------
 * Halt
 * -------------------------------------------------------------------------- */
static void _halt(const char *reason) __attribute__((noreturn));
static void _halt(const char *reason) {
    uart_puts("\n[FATAL] ");
    uart_puts(reason);
    uart_puts("\n[FATAL] System halted.\n");
    for (;;) __asm__ volatile("wfi");
}

/* --------------------------------------------------------------------------
 * sage_kernel_main — called from boot/arch/rv64/boot.S
 * -------------------------------------------------------------------------- */
void sage_kernel_main(uint64_t hart_id, uint64_t dtb_addr) {
    (void)hart_id;
    (void)dtb_addr;

    uart_init();
    uart_puts("SBIK!\n");
    uart_puts("[MetalRV64] Initializing...\n");

    /* Run kernel blob */
    const uint8_t *kblob = _binary_kernel_core_kmain_sgvm_start;
    int            ksz   = (int)(_binary_kernel_core_kmain_sgvm_end - kblob);

    if (ksz > 8) {
        MetalRV64VM kernel_vm;
        metal_rv64_vm_init(&kernel_vm);
        kernel_vm.write_char = uart_putc;
        kernel_vm.read_char  = uart_getchar;
        metal_rv64_vm_register_kernel_builtins(&kernel_vm);

        int err = metal_rv64_vm_load_binary(&kernel_vm, kblob, ksz);
        if (err == 0) {
            for (int i = 0; i < kernel_vm.chunk_count; i++) {
                kernel_vm.current_chunk_idx = i;
                kernel_vm.bytecode = kernel_vm.chunks[i];
                kernel_vm.bytecode_length = kernel_vm.chunk_lengths[i];
                kernel_vm.pc = 0;
                metal_rv64_vm_run(&kernel_vm);
            }
        }
    }

    /* Run shell blob */
    const uint8_t *sblob = _binary_shell_shell_sgvm_start;
    int            ssz   = (int)(_binary_shell_shell_sgvm_end - sblob);

    if (ssz <= 8)
        _halt("shell.sgvm blob is empty");

    uart_puts("[MetalRV64] Running shell...\n");

    MetalRV64VM rv64_vm;
    metal_rv64_vm_init(&rv64_vm);
    rv64_vm.write_char = uart_putc;
    rv64_vm.read_char  = uart_getchar;
    metal_rv64_vm_register_kernel_builtins(&rv64_vm);

    int err = metal_rv64_vm_load_binary(&rv64_vm, sblob, ssz);
    if (err != 0)
        _halt("metal_rv64_vm_load_binary() failed for shell");

    int rc = 0;
    for (int i = 0; i < rv64_vm.chunk_count; i++) {
        rv64_vm.current_chunk_idx = i;
        rv64_vm.bytecode = rv64_vm.chunks[i];
        rv64_vm.bytecode_length = rv64_vm.chunk_lengths[i];
        rv64_vm.pc = 0;
        rc = metal_rv64_vm_run(&rv64_vm);
        if (rc < 0) {
            uart_puts("[MetalRV64] Chunk ");
            if (i >= 10) uart_putc('0' + (i / 10) % 10);
            uart_putc('0' + (i % 10));
            uart_puts(" error: ");
            if (rv64_vm.error_msg) uart_puts(rv64_vm.error_msg);
            uart_puts("\n");
            break;
        }
    }

    if (rc < 0) {
        uart_puts("[MetalRV64] shell exited with error\n");
    } else {
        uart_puts("[MetalRV64] shell returned (unexpected)\n");
    }

    _halt("Shell returned from MetalRV64");
}
