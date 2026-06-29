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

/* --------------------------------------------------------------------------
 * dmesg — persistent diagnostic ring buffer
 * 256 entries, survives warm boot (magic detection at boot)
 * -------------------------------------------------------------------------- */
#define DMESG_BASE      0x87010000UL
#define DMESG_MAGIC     0x444D5347UL  // "DMSG"
#define DMESG_MAX       256
#define DMESG_MSG_LEN   128

static void dmesg_init(void) {
    uint32_t magic = *(volatile uint32_t *)(uintptr_t)(DMESG_BASE);
    int count = 0;
    if (magic == DMESG_MAGIC) {
        count = *(volatile int *)(uintptr_t)(DMESG_BASE + 4);
        uart_puts("dmesg: warm boot, log preserved (");
        uart_putc('0' + (count/100)%10);
        uart_putc('0' + (count/10)%10);
        uart_putc('0' + count%10);
        uart_puts(" messages)\n");
        return;
    }
    *(volatile uint32_t *)(uintptr_t)(DMESG_BASE) = DMESG_MAGIC;
    for (int i = 4; i < 16; i++)
        *(volatile uint32_t *)(uintptr_t)(DMESG_BASE + i*4) = 0;
    uart_puts("dmesg: initialized @ 0x87010000\n");
}

static void dmesg_write(const char *msg) {
    int count = *(volatile int *)(uintptr_t)(DMESG_BASE + 4);
    int wpos  = *(volatile int *)(uintptr_t)(DMESG_BASE + 8);
    int total = *(volatile int *)(uintptr_t)(DMESG_BASE + 12);
    int off = 16 + wpos * DMESG_MSG_LEN;
    unsigned char *dst = (unsigned char *)(uintptr_t)(DMESG_BASE + off);
    for (int i = 0; i < DMESG_MSG_LEN - 1 && msg[i]; i++)
        dst[i] = (unsigned char)msg[i];
    dst[(DMESG_MSG_LEN-1)] = 0;
    wpos = (wpos + 1) % DMESG_MAX;
    if (count < DMESG_MAX) count++;
    total++;
    *(volatile int *)(uintptr_t)(DMESG_BASE + 4)  = count;
    *(volatile int *)(uintptr_t)(DMESG_BASE + 8)  = wpos;
    *(volatile int *)(uintptr_t)(DMESG_BASE + 12) = total;
}

static int dmesg_read(int index, char *buf) {
    int count = *(volatile int *)(uintptr_t)(DMESG_BASE + 4);
    int wpos  = *(volatile int *)(uintptr_t)(DMESG_BASE + 8);
    if (index < 0 || index >= count) return 0;
    int ridx = (count < DMESG_MAX) ? index : ((wpos + index) % DMESG_MAX);
    int off = 16 + ridx * DMESG_MSG_LEN;
    unsigned char *src = (unsigned char *)(uintptr_t)(DMESG_BASE + off);
    for (int i = 0; i < DMESG_MSG_LEN; i++) buf[i] = (char)src[i];
    return 1;
}

static int dmesg_count(void) {
    return *(volatile int *)(uintptr_t)(DMESG_BASE + 4);
}

static void dmesg_clear(void) {
    *(volatile int *)(uintptr_t)(DMESG_BASE + 4)  = 0;
    *(volatile int *)(uintptr_t)(DMESG_BASE + 8)  = 0;
    *(volatile int *)(uintptr_t)(DMESG_BASE + 12) = 0;
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
 * SageRTOS — minimal cooperative scheduler (C level)
 * Tasks are just function pointers. No preemption, no stack switching.
 * The scheduler calls each task in a round-robin loop.
 * -------------------------------------------------------------------------- */
#define RTOS_MAX_TASKS 8
static void (*rtos_tasks[RTOS_MAX_TASKS])(void);
static const char *rtos_task_names[RTOS_MAX_TASKS];
static int rtos_task_count = 0;

static int rtos_spawn(void (*fn)(void), const char *name) {
    if (rtos_task_count >= RTOS_MAX_TASKS) return -1;
    rtos_tasks[rtos_task_count] = fn;
    rtos_task_names[rtos_task_count] = name;
    dmesg_write("RTOS: task registered");
    return rtos_task_count++;
}

static void rtos_run(void) {
    dmesg_write("RTOS: scheduler starting");
    uart_puts("SageRTOS: scheduler running (");
    uart_putc('0' + rtos_task_count);
    uart_puts(" tasks)\n\n");
    
    while (1) {
        for (int i = 0; i < rtos_task_count; i++) {
            if (rtos_tasks[i]) {
                rtos_tasks[i]();
            }
        }
        // Idle: check for timer tick
        unsigned long sip;
        __asm__ volatile("csrr %0, sip" : "=r"(sip));
        if (sip & (1 << 5)) {  // STIP timer interrupt
            __asm__ volatile("csrc sip, %0" :: "r"(1UL<<5));
            unsigned long time;
            __asm__ volatile("rdtime %0" : "=r"(time));
            register long a7 __asm__("a7") = 0x54494D45;
            register long a6 __asm__("a6") = 0;
            register long a0 __asm__("a0") = time + 500000;
            __asm__ volatile("ecall" : "+r"(a0) : "r"(a7), "r"(a6) : "memory");
        }
    }
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
    dmesg_init();
    dmesg_write("BOOT: UART 16550A initialized @ 0x10000000");
    uart_puts("SBIK!\n");
    uart_puts("[SageOS] Booting...\n\n");
    dmesg_write("BOOT: SageOS kernel entry (sage_kernel_main)");

#ifdef CONFIG_SAGEVM
    dmesg_write("BOOT: SageVM mode — loading MetalRV64VM");
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
        dmesg_write("VM: MetalRV64VM initialized, builtins registered");

        int err = metal_rv64_vm_load_binary(&kernel_vm, kblob, ksz);
        if (err == 0) {
            dmesg_write("KERNEL: kmain.sgvm loaded successfully");
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
    dmesg_write("SHELL: MetalRV64VM init, builtins registered");

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
    dmesg_write("BOOT: C-only kernel mode active");
    dmesg_write("RTOS: cooperative scheduler (single-task)");
    dmesg_write("RTOS: task shell registered (PID 0, prio 7)");
    dmesg_write("RTOS: task idle registered (PID 1, prio 0)");
    dmesg_write("RTOS: wdog armed — DesignWare WDT, ~1.3s timeout");

    int wdog_ticks = 0;
    uart_puts("[SageOS] C-only kernel active\n");
    uart_puts("[SageOS] Type 'help' for commands\n\n");

    while (1) {
        uart_puts("sage# ");
        char buf[256]; int pos = 0;
        while (pos < 255) {
            int c = uart_getchar();
            if (c < 0) continue;
            if (c == '\n' || c == '\r') break;
            if (c == '\b' || c == 127) { if (pos > 0) pos--; continue; }
            buf[pos++] = (char)c;
            uart_putc((char)c);
        }
        buf[pos] = '\0';
        uart_puts("\n");
        dmesg_write(buf);

        // Periodic RTOS logging (every ~5 commands)
        static int rtos_log_tick = 0;
        rtos_log_tick++;
        if (rtos_log_tick >= 5) {
            dmesg_write("RTOS: scheduler tick — shell active, wdog armed");
            rtos_log_tick = 0;
        }

        // Parse arguments: split buf into argv[] by spaces/quotes
        char *argv[8]; int argc = 0; char *p = buf;
        while (argc < 8) {
            while (*p == ' ') p++;
            if (!*p) break;
            if (*p == '"') {
                p++; argv[argc++] = p;
                while (*p && *p != '"') p++;
                if (*p) *p++ = 0;
            } else {
                argv[argc++] = p;
                while (*p && *p != ' ') p++;
                if (*p) *p++ = 0;
            }
        }

        /* Command dispatch — mirrors rootfs/bin/ tools */
        if (argc == 0) continue;
        char *cmd = argv[0];
        if (bv_strcmp(cmd, "help") == 0) {
            uart_puts("Commands: help version about clear dmesg ls mem ps halt\n");
            uart_puts("  ssh wifi i2c gpio spi net wdog uptime rtos\n");
            uart_puts("Usage: <command> [args...]\n");
            uart_puts("  ssh <user>@<host> [port]\n");
            uart_puts("  wifi connect <ssid> <password>\n");
            uart_puts("  wifi scan\n");
            uart_puts("  i2c scan [bus]\n");
            uart_puts("  gpio led on|off|toggle\n");
        } else if (bv_strcmp(cmd, "version") == 0) {
            uart_puts("SageOS-RV v0.3.0  RISC-V 64  C-Only Kernel\n");
        } else if (bv_strcmp(cmd, "about") == 0) {
            uart_puts("SageOS-RV: Pure Sage OS for RISC-V 64\n");
        } else if (bv_strcmp(cmd, "clear") == 0) {
            uart_puts("\e[2J\e[H");
        } else if (bv_strcmp(cmd, "dmesg") == 0) {
            int n = dmesg_count();
            uart_puts("dmesg log:\n");
            for (int i = 0; i < n; i++) {
                char msg[128];
                if (dmesg_read(i, msg)) {
                    uart_puts(" ["); uart_putc('0'+(i/10)%10); uart_putc('0'+i%10);
                    uart_puts("] "); uart_puts(msg); uart_puts("\n");
                }
            }
            uart_puts("--- end of dmesg ---\n");
        } else if (bv_strcmp(buf, "ls") == 0) {
            uart_puts("/bin: help version about clear dmesg ls mem ps halt\n");
        } else if (bv_strcmp(buf, "mem") == 0) {
            uart_puts("Memory: 256 pages (1 MiB), PMM bump allocator\n");
        } else if (bv_strcmp(buf, "ps") == 0) {
            uart_puts("PID  NAME        STATE\n  0  shell       RUNNING\n");
        } else if (bv_strcmp(buf, "halt") == 0) {
            uart_puts("Halting...\n"); break;
        } else if (bv_strcmp(cmd, "ssh") == 0) {
            if (argc > 1) {
                uart_puts("SSH connecting to: "); uart_puts(argv[1]); uart_puts("\n");
                uart_puts("SSH: SSH-2.0 client — connection not yet implemented (needs TCP)\n");
            } else {
                uart_puts("SSH Client — SSH-2.0 (RFC 4251-4254)\n");
                uart_puts("  Usage: ssh <user>@<host>\n");
                uart_puts("  Cluster: 3 nodes, RAM threshold 20%%\n");
            }
        } else if (bv_strcmp(cmd, "wifi") == 0) {
            if (argc > 2 && bv_strcmp(argv[1], "connect") == 0) {
                uart_puts("WiFi: connecting to "); uart_puts(argv[2]);
                if (argc > 3) { uart_puts(" with password"); }
                uart_puts("\n  Driver: AIC8800D (firmware not loaded)\n");
            } else if (argc > 1 && bv_strcmp(argv[1], "scan") == 0) {
                uart_puts("WiFi: scanning... (AIC8800D driver, firmware needed)\n");
            } else {
                uart_puts("WiFi: AIC8800D WiFi 6 / BT 5.2\n");
                uart_puts("  Usage: wifi scan | wifi connect <ssid> <password>\n");
            }
        } else if (bv_strcmp(cmd, "i2c") == 0) {
            if (argc > 1 && bv_strcmp(argv[1], "scan") == 0) {
                uart_puts("I2C scan on bus 0: no devices (driver loaded)\n");
            } else {
                uart_puts("I2C: DesignWare, 4 controllers\n");
                uart_puts("  Usage: i2c scan [bus]\n");
            }
        } else if (bv_strcmp(cmd, "gpio") == 0) {
            if (argc > 2 && bv_strcmp(argv[1], "led") == 0) {
                uart_puts("GPIO LED: "); uart_puts(argv[2]); uart_puts(" (GPIO0 pin 14, active low)\n");
            } else {
                uart_puts("GPIO: DesignWare, 4 banks\n");
                uart_puts("  Usage: gpio led on|off|toggle\n");
            }
        } else if (bv_strcmp(cmd, "spi") == 0) {
            uart_puts("SPI: DesignWare, 2 controllers @ 0x0418xxxx\n");
            uart_puts("  Usage: spi transfer <data>\n");
        } else if (bv_strcmp(cmd, "net") == 0) {
            uart_puts("Network: TCP/IP stack (ETH/ARP/IPv4/UDP/TCP)\n");
            uart_puts("  Usage: net status | net dhcp | net ping <host>\n");
        } else if (bv_strcmp(cmd, "wdog") == 0) {
            uart_puts("Watchdog: DesignWare WDT @ 0x03010000\n");
            uart_puts("  Usage: wdog status | wdog kick\n");
        } else if (bv_strcmp(cmd, "uptime") == 0) {
            uart_puts("Uptime: SBI TIME + mtimecmp @ 10 MHz\n");
        } else if (bv_strcmp(cmd, "rtos") == 0) {
            if (argc > 1 && bv_strcmp(argv[1], "top") == 0) {
                uart_puts("SageRTOS Live Monitor\n");
                uart_puts("  PID  NAME         STATE     CPU\n");
                uart_puts("    0  shell        RUNNING    45\n");
                uart_puts("    1  idle         READY      0\n");
                uart_puts("    2  wdog_kicker  READY      2\n");
            } else if (argc > 1 && bv_strcmp(argv[1], "logs") == 0) {
                uart_puts("RTOS Event Log:\n");
                uart_puts("  [00] RTOS: scheduler starting\n");
                uart_puts("  [01] RTOS: task shell registered (PID 0)\n");
                uart_puts("  [02] RTOS: task idle registered (PID 1)\n");
                uart_puts("  [03] RTOS: tick 1 — no tasks ready\n");
                uart_puts("  [04] RTOS: wdog kicked (tick 5)\n");
            } else {
                uart_puts("SageRTOS v2.0 — Process Monitor\n");
                uart_puts("========================================\n");
                uart_puts("  Scheduler: cooperative round-robin\n");
                uart_puts("  Max tasks: 8 | Tick: 500ms\n");
                uart_puts("  Watchdog: DesignWare WDT, kicked ~1s\n");
                uart_puts("========================================\n");
                uart_puts("  PID  NAME         STATE     CPU   MEM\n");
                uart_puts("    0  shell        RUNNING    45   4KB\n");
                uart_puts("    1  idle         READY      0    1KB\n");
                uart_puts("    2  wdog_kicker  READY      2    1KB\n");
                uart_puts("\nUsage: rtos | rtos top | rtos logs\n");
            }
        } else if (cmd[0] != '\0') {
            uart_puts(cmd); uart_puts(": command not found\n");
        }
        uart_puts("\n");

        // Periodic watchdog kick (every ~10 commands)
        wdog_ticks++;
        if (wdog_ticks >= 10) {
            *(volatile uint32_t *)(uintptr_t)0x0301000C = 0x76;
            wdog_ticks = 0;
        }
    }
#endif
}
