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
    while ((_r8(UART_BASE + UART_LSR) & UART_THRE) == 0);
    _w8(UART_BASE + UART_THR, (uint8_t)c);
}

static int uart_getchar(void) {
    // Direct UART poll — no SBI blocking
    if (_r8(UART_BASE + UART_LSR) & UART_DR)
        return (int)_r8(UART_BASE + UART_RBR);
    return -1;
}

static void uart_puts(const char *s) {
    while (*s) uart_putc(*s++);
}

static int bv_strcmp(const char *a, const char *b) {
    while (*a && *a == *b) { a++; b++; }
    return *(unsigned char *)a - *(unsigned char *)b;
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
extern const uint8_t _binary_shell_shell_sgvm_start[];
extern const uint8_t _binary_shell_shell_sgvm_end[];

#ifdef CONFIG_SAGEVM
extern const uint8_t _binary_kernel_core_kmain_sgvm_start[];
extern const uint8_t _binary_kernel_core_kmain_sgvm_end[];
#endif

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
    uart_puts("[SageOS] Booting...\n\n");

#ifdef CONFIG_SAGEVM
    /* Run kernel blob via MetalRV64VM */
    uart_puts("[MetalRV64] Initializing...\n");
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
    // Phase 1: run definition chunks first (SET globals before GET)
    int def_count = rv64_vm.chunk_count - 1;  // all chunks except main body
    for (int i = 1; i < rv64_vm.chunk_count; i++) {
        rv64_vm.current_chunk_idx = i;
        rv64_vm.bytecode = rv64_vm.chunks[i];
        rv64_vm.bytecode_length = rv64_vm.chunk_lengths[i];
        rv64_vm.pc = 0;
        rc = metal_rv64_vm_run(&rv64_vm);
        if (rc < 0) {
            // Non-fatal: some chunks may reference unregistered constants
            continue;
        }
    }
    // Phase 2: run main body (chunk 0) with all globals registered
    if (rc == 0 && rv64_vm.chunk_count > 0) {
        rv64_vm.current_chunk_idx = 0;
        rv64_vm.bytecode = rv64_vm.chunks[0];
        rv64_vm.bytecode_length = rv64_vm.chunk_lengths[0];
        rv64_vm.pc = 0;
        rc = metal_rv64_vm_run(&rv64_vm);
        if (rc < 0) {
            uart_puts("[MetalRV64] Chunk 0 error: ");
            if (rv64_vm.error_msg) uart_puts(rv64_vm.error_msg);
            uart_puts("\n");
        }
    }

    if (rc < 0) {
        uart_puts("[MetalRV64] shell exited with error\n");
    } else {
        uart_puts("[MetalRV64] shell returned (unexpected)\n");
    }

    _halt("Shell returned from MetalRV64");
#else  /* !CONFIG_SAGEVM — C-only kernel */
    uart_puts("[SageOS] C-only kernel active\n");
    uart_puts("[SageOS] Type 'help' for commands\n\n");

    /* Simple C shell loop */
    while (1) {
        uart_puts("sage# ");
        char buf[256]; int pos = 0;
        while (pos < 255) {
            int c = uart_getchar();
            if (c < 0) { __asm__ volatile("wfi"); continue; }
            if (c == '\n' || c == '\r') break;
            if (c == '\b' || c == 127) { if (pos > 0) pos--; continue; }
            buf[pos++] = (char)c;
            uart_putc((char)c);
        }
        buf[pos] = '\0';
        uart_puts("\n");
        /* Simple command dispatch */
        if (bv_strcmp(buf, "help") == 0) {
            uart_puts("Commands: help version about clear mem halt\n");
        } else if (bv_strcmp(buf, "version") == 0) {
            uart_puts("SageOS-RV v0.3.0  RISC-V 64  C-Only Kernel\n");
        } else if (bv_strcmp(buf, "about") == 0) {
            uart_puts("SageOS-RV: Pure Sage OS for RISC-V 64\n");
        } else if (bv_strcmp(buf, "clear") == 0) {
            uart_puts("\e[2J\e[H");
        } else if (bv_strcmp(buf, "mem") == 0) {
            uart_puts("Memory: 256 pages, 1 MiB, PMM bump allocator\n");
        } else if (bv_strcmp(buf, "halt") == 0) {
            uart_puts("Halting...\n"); break;
        } else if (buf[0] != '\0') {
            uart_puts("Unknown: "); uart_puts(buf); uart_puts("\n");
        }
        uart_puts("\n");
    }
#endif
}
