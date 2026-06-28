/* kernel/fallback_kernel.c — Fallback C kernel for SageOS-RV
 *
 * This is the minimal C kernel that boots when Sage transpilation
 * is not yet available for bare-metal. It demonstrates the boot
 * chain works and provides a platform for testing.
 *
 * As SageLang's bare-metal code generation matures, this file
 * will be replaced by transpiled Sage code.
 *
 * NOTE: SRVM (Sage RISC-V VM) is a pure Sage module. It is
 * available via kmain.sage -> sage --emit-c transpilation.
 * This C fallback reports its availability but cannot invoke
 * it directly — there is no C API, by design.
 */

#include <stdint.h>
#include "sbi.h"
#include "dtb.h"
#include "vmm.h"

/* Forward declarations for freestanding */
typedef uint64_t size_t;
static int strncmp(const char *a, const char *b, int n);
static size_t strlen(const char *s);

/* Volatile tick counter updated by timer interrupt */
static volatile uint64_t system_ticks = 0;

/* DTB-discovered hardware info (populated at boot) */
static dtb_info_t hw;

/* UART registers (16550A) */
#define UART_THR    0
#define UART_RBR    0
#define UART_IER    1
#define UART_FCR    2
#define UART_LCR    3
#define UART_LSR    5
#define UART_LSR_THRE 0x20
#define UART_LSR_DR   0x01

/* Timer frequency (from DTB or default) */
#define TIMER_FREQ  (hw.timer_freq > 0 ? hw.timer_freq : 10000000UL)

/* Memory-mapped I/O helpers (byte accesses for 8250 UART) */
static inline void mmio_write(uint64_t addr, uint8_t val) {
    *(volatile uint8_t *)addr = val;
}

static inline uint8_t mmio_read(uint64_t addr) {
    return *(volatile uint8_t *)addr;
}

/* UART functions */
static uint64_t uart_base(void) {
    return hw.uart_base ? hw.uart_base : 0x10000000UL;
}

static void uart_init(void) {
    uint64_t base = uart_base();
    mmio_write(base + UART_IER, 0);     /* Disable interrupts */
    mmio_write(base + UART_FCR, 0xC7);  /* Enable FIFO, clear, 14-byte threshold */
    mmio_write(base + UART_LCR, 0x03);  /* 8N1 */
}

static void uart_putc(char c) {
    uint64_t base = uart_base();
    while ((mmio_read(base + UART_LSR) & UART_LSR_THRE) == 0)
        ;
    mmio_write(base + UART_THR, (uint8_t)c);
}

static void uart_puts(const char *s) {
    while (*s) {
        if (*s == '\n')
            uart_putc('\r');
        uart_putc(*s++);
    }
}

static int uart_getchar(void) {
    uint64_t base = uart_base();
    if (mmio_read(base + UART_LSR) & UART_LSR_DR)
        return mmio_read(base + UART_RBR);
    return -1;
}

static void uart_put_hex(uint64_t val) {
    uart_puts("0x");
    int started = 0;
    for (int i = 60; i >= 0; i -= 4) {
        uint64_t nibble = (val >> i) & 0xF;
        if (nibble || started || i == 0) {
            if (nibble < 10)
                uart_putc('0' + nibble);
            else
                uart_putc('A' + nibble - 10);
            started = 1;
        }
    }
}

static void uart_put_dec(uint64_t val) {
    if (val == 0) {
        uart_putc('0');
        return;
    }
    char buf[20];
    int pos = 19;
    buf[pos--] = '\0';
    while (val > 0) {
        buf[pos--] = '0' + (val % 10);
        val /= 10;
    }
    uart_puts(&buf[pos + 1]);
}

/* Memory manager — bitmap-based, 1 bit per 4K page */
#define PAGE_SIZE 4096UL
#define PAGE_SHIFT 12

/* Linker symbols — take their address to get the actual value */
extern char _heap_start[];
extern char _heap_end[];
extern char _stack_top[];
extern char _image_end[];

static uint64_t mem_base;
static uint64_t mem_size;
static uint64_t total_pages;
static uint64_t free_pages;
static uint64_t *bitmap;
static uint64_t bitmap_words;

static void pmm_mark_used(uint64_t page_idx) {
    uint64_t word = page_idx / 64;
    uint64_t bit  = page_idx % 64;
    bitmap[word] &= ~(1ULL << bit);
    free_pages--;
}

static void pmm_mark_free(uint64_t page_idx) {
    uint64_t word = page_idx / 64;
    uint64_t bit  = page_idx % 64;
    bitmap[word] |= (1ULL << bit);
    free_pages++;
}

static void pmm_init(void) {
    mem_base = hw.mem_base ? hw.mem_base : 0x80200000UL;
    mem_size = hw.mem_size ? hw.mem_size : (128UL * 1024 * 1024);
    total_pages = mem_size / PAGE_SIZE;
    free_pages = total_pages;
    bitmap_words = (total_pages + 63) / 64;

    /* Bitmap sits right after the kernel image (at _heap_start) */
    bitmap = (uint64_t *)(uint64_t)_heap_start;

    /* Mark all pages free (1 = free) */
    for (uint64_t i = 0; i < bitmap_words; i++)
        bitmap[i] = ~0ULL;

    /* Reserve kernel image pages (first ~256) and bitmap itself */
    uint64_t kernel_pages = 256;
    uint64_t bitmap_pages = (bitmap_words * 8 + PAGE_SIZE - 1) / PAGE_SIZE;
    for (uint64_t i = 0; i < kernel_pages + bitmap_pages; i++)
        pmm_mark_used(i);
}

uint64_t pmm_alloc(void) {
    if (free_pages == 0) return 0;
    for (uint64_t w = 0; w < bitmap_words; w++) {
        uint64_t word = bitmap[w];
        if (word == 0) continue;
        uint64_t bit = 0;
        while ((word & 1) == 0) { word >>= 1; bit++; }
        uint64_t page_idx = w * 64 + bit;
        if (page_idx < total_pages) {
            pmm_mark_used(page_idx);
            return mem_base + page_idx * PAGE_SIZE;
        }
    }
    return 0;
}

static void pmm_free(uint64_t addr) {
    uint64_t page_idx = (addr - mem_base) / PAGE_SIZE;
    if (page_idx < total_pages)
        pmm_mark_free(page_idx);
}

/* Shell */
static int shell_running = 1;

static void cmd_help(void) {
    uart_puts("SageOS-RV Shell Commands:\n");
    uart_puts("  help       Show this help\n");
    uart_puts("  version    Show kernel version\n");
    uart_puts("  mem        Show memory statistics\n");
    uart_puts("  srvm       SRVM status (Sage transpilation required)\n");
    uart_puts("  clear      Clear screen\n");
    uart_puts("  uptime     Show system uptime\n");
    uart_puts("  reboot     Cold reboot the system\n");
    uart_puts("  poweroff   Shut down the system\n");
    uart_puts("  halt       Halt the CPU (WFI loop)\n");
    uart_puts("  about      About SageOS\n");
    uart_puts("  echo <text> Print text\n\n");
}

static void cmd_version(void) {
    uart_puts("SageOS-RV v0.1.0-alpha\n");
    uart_puts("Kernel: SageOS-RV\n");
    uart_puts("Arch: RISC-V 64 (rv64imac)\n");
    uart_puts("SBI: v3.0\n");
    uart_puts("Build: fallback C kernel (Sage transpilation pending)\n");
    uart_puts("VM:    SRVM (available after sage --emit-c transpilation)\n\n");
}

static void cmd_mem(void) {
    uint64_t used = total_pages - free_pages;
    uart_puts("Memory Statistics:\n");
    uart_puts("  Base:  ");
    uart_put_hex(mem_base);
    uart_puts("\n  Size:  ");
    uart_put_dec(mem_size / 1024);
    uart_puts(" KB\n");
    uart_puts("  Total pages: ");
    uart_put_dec(total_pages);
    uart_puts("\n  Free pages:  ");
    uart_put_dec(free_pages);
    uart_puts("\n  Used pages:  ");
    uart_put_dec(used);
    uart_puts(" (");
    uart_put_dec(used * 100 / total_pages);
    uart_puts("%)\n");
    uart_puts("  Free KB:     ");
    uart_put_dec(free_pages * 4);
    uart_puts("\n\n");
}

static void cmd_srvm(void) {
    uart_puts("SRVM (Sage RISC-V VM):\n");
    uart_puts("  Source: github.com/Night-Traders-Dev/SageVM src/srvm/\n");
    uart_puts("  Status: unavailable in C fallback kernel\n");
    uart_puts("  Reason: SRVM is a pure Sage module (srvm_vm.sage +\n");
    uart_puts("          srvm_core.sage). It is instantiated from\n");
    uart_puts("          kmain.sage via 'import srvm_vm' and compiled\n");
    uart_puts("          by 'sage --emit-c kernel/kmain.sage'.\n");
    uart_puts("  Action: run './sagemake build' with a working Sage\n");
    uart_puts("          compiler to get SRVM in the kernel.\n\n");
}

static void cmd_clear(void) {
    uart_puts("\033[2J\033[H");
}

static void cmd_uptime(void) {
    uart_puts("System uptime: ");
    uart_put_dec(system_ticks);
    uart_puts(" seconds\n");
}

static void cmd_about(void) {
    uart_puts("SageOS-RV -- A Pure Sage Operating System\n");
    uart_puts("Target: LicheeRV Nano (Sophgo SG2002, RISC-V 64)\n");
    uart_puts("Philosophy: C only where silicon requires it.\n");
    uart_puts("            Everything else is Pure Sage.\n\n");
    uart_puts("VM: SRVM from SageVM (github.com/Night-Traders-Dev/SageVM)\n");
    uart_puts("    RV64I bytecode interpreter, pure Sage, no libc.\n\n");
}

static void process_command(const char *line) {
    if (line[0] == '\0')
        return;

    const char *cmd = line;
    const char *args = line;
    while (*args && *args != ' ')
        args++;
    int cmd_len = args - cmd;
    if (*args == ' ')
        args++;

    if (strncmp(cmd, "help", cmd_len) == 0 && cmd_len == 4) {
        cmd_help();
    } else if (strncmp(cmd, "version", cmd_len) == 0 && cmd_len == 7) {
        cmd_version();
    } else if (strncmp(cmd, "mem", cmd_len) == 0 && cmd_len == 3) {
        cmd_mem();
    } else if (strncmp(cmd, "srvm", cmd_len) == 0 && cmd_len == 4) {
        cmd_srvm();
    } else if (strncmp(cmd, "clear", cmd_len) == 0 && cmd_len == 5) {
        cmd_clear();
    } else if (strncmp(cmd, "uptime", cmd_len) == 0 && cmd_len == 6) {
        cmd_uptime();
    } else if (strncmp(cmd, "about", cmd_len) == 0 && cmd_len == 5) {
        cmd_about();
    } else if (strncmp(cmd, "reboot", cmd_len) == 0 && cmd_len == 6) {
        uart_puts("System rebooting...\n");
        sbi_cold_reboot();
    } else if (strncmp(cmd, "poweroff", cmd_len) == 0 && cmd_len == 8) {
        uart_puts("System powering off...\n");
        sbi_shutdown();
    } else if (strncmp(cmd, "halt", cmd_len) == 0 && cmd_len == 4) {
        uart_puts("System halting...\n");
        shell_running = 0;
    } else if (strncmp(cmd, "echo", cmd_len) == 0 && cmd_len == 4) {
        uart_puts(args);
        uart_puts("\n");
    } else {
        uart_puts("Unknown command. Type 'help' for available commands.\n");
    }
}

/* Simple string comparison */
static int strncmp(const char *a, const char *b, int n) {
    for (int i = 0; i < n; i++) {
        if (a[i] != b[i])
            return a[i] - b[i];
        if (a[i] == '\0')
            return 0;
    }
    return 0;
}

static size_t strlen(const char *s) {
    size_t len = 0;
    while (s[len])
        len++;
    return len;
}

/* Timer helpers */
static int use_sstc = 0;

static void timer_arm(uint64_t deadline) {
    if (use_sstc) {
        __asm__ volatile("csrw 0x14D, %0" :: "r"(deadline));
    } else {
        sbi_set_timer(deadline);
    }
}

/* Poll for and handle pending timer tick (forward declaration) */
static void timer_poll(void);

/* Get character from UART or SBI (non-blocking poll of both) */
static int console_getchar(void) {
    int c;
    c = uart_getchar();
    if (c >= 0)
        return c;
    c = sbi_console_getchar();
    return c;
}

/* Shell main loop with periodic timer polling */
static void shell_main(void) {
    uart_puts("SageOS-RV Shell (type 'help' for commands)\n\n");

    char buf[256];
    while (shell_running) {
        timer_poll();
        uart_puts("sage# ");

        int pos = 0;
        buf[0] = '\0';

        while (1) {
            int c = -1;
            for (int tries = 0; tries < 1000; tries++) {
                c = console_getchar();
                if (c >= 0)
                    break;
                timer_poll();
            }
            if (c < 0) {
                timer_poll();
                continue;
            }

            if (c == '\r' || c == '\n') {
                uart_putc('\r');
                uart_putc('\n');
                buf[pos] = '\0';
                break;
            } else if (c == 0x7F || c == '\b') {
                if (pos > 0) {
                    pos--;
                    buf[pos] = '\0';
                    uart_putc('\b');
                    uart_putc(' ');
                    uart_putc('\b');
                }
            } else if (c >= 32 && c < 127) {
                if (pos < 255) {
                    buf[pos++] = (char)c;
                    uart_putc((char)c);
                }
            }
        }

        process_command(buf);
    }
}

/* Poll for and handle pending timer tick */
static void timer_poll(void) {
    uint64_t sip_val;
    __asm__ volatile("csrr %0, sip" : "=r"(sip_val));
    if (sip_val & 0x20) {
        system_ticks++;
        uint64_t time;
        __asm__ volatile("rdtime %0" : "=r"(time));
        timer_arm(time + TIMER_FREQ / 2);
    }
}

/* Start the periodic timer — try SSTC stimecmp first, fall back to SBI */
static void timer_start(void) {
    uint64_t time;
    __asm__ volatile("rdtime %0" : "=r"(time));

    uint64_t probe_val = 0xAAAA5555AAAA5555UL;
    uint64_t readback = 0;
    __asm__ volatile("csrw 0x14D, %1\n\t"
                     "csrr %0, 0x14D"
                     : "=r"(readback)
                     : "r"(probe_val)
                     : "memory");
    if (readback == probe_val) {
        use_sstc = 1;
        timer_arm(time + TIMER_FREQ / 2);
        uart_puts("stimecmp @ ");
        uart_put_dec(TIMER_FREQ / 1000000);
        uart_puts(" MHz, 500ms\n");
    } else {
        timer_arm(time + TIMER_FREQ / 2);
        uart_puts("SBI @ ");
        uart_put_dec(TIMER_FREQ / 1000000);
        uart_puts(" MHz, 500ms\n");
    }
    __asm__ volatile("csrs sie, %0" :: "r"(0x20));
}

/* Kernel main — called from boot.S */
/* a0 = hart_id, a1 = DTB address (OpenSBI S-mode convention) */
void sage_kernel_main(uint64_t hart_id, uint64_t dtb_addr) {
    uart_init();

    uart_puts("\n");
    uart_puts("========================================\n");
    uart_puts("  SageOS-RV v0.1.0-alpha\n");
    uart_puts("  Pure Sage Operating System\n");
    uart_puts("  RISC-V 64 | QEMU virt\n");
    uart_puts("========================================\n\n");

    uart_puts("[1/7] Console initialized\n");

    /* Parse device tree to discover hardware */
    int dtb_ok = dtb_parse(dtb_addr, &hw);
    if (dtb_ok == 0) {
        uart_puts("  DTB: ");
        uart_put_hex(hw.mem_size / 1024);
        uart_puts(" KB @ ");
        uart_put_hex(hw.mem_base);
        uart_puts(", timer ");
        uart_put_dec(hw.timer_freq / 1000000);
        uart_puts(" MHz\n");
        uart_puts("       UART @ ");
        uart_put_hex(hw.uart_base);
        uart_puts(", PLIC @ ");
        uart_put_hex(hw.plic_base);
        uart_puts(", CPUs ");
        uart_put_dec(hw.cpu_count);
        uart_puts("\n");
    } else {
        uart_puts("  DTB: fallback defaults\n");
    }

    /* Re-init UART in case DTB reported a different base */
    uart_init();

    uart_puts("[2/7] Memory: ");
    pmm_init();
    uart_put_dec(total_pages);
    uart_puts(" pages (");
    uart_put_dec(mem_size / 1024);
    uart_puts(" KB) — ");
    uart_put_dec(bitmap_words);
    uart_puts(" bitmap words\n");

    uart_puts("[3/7] VMM: ");
    int vmm_ok = vmm_init();
    if (vmm_ok == 0) {
        /* Identity map kernel code + data */
        vmm_identity_map(0x80200000UL, 0x81000000UL,
                         PTE_R | PTE_W | PTE_X | PTE_G);
        /* Identity map UART MMIO */
        vmm_identity_map(hw.uart_base, hw.uart_base + 0x1000,
                         PTE_R | PTE_W | PTE_G);
        /* Identity map PLIC */
        if (hw.plic_base)
            vmm_identity_map(hw.plic_base, hw.plic_base + 0x400000,
                             PTE_R | PTE_W | PTE_G);
        vmm_activate();
        uart_puts("SV39 active\n");
    } else {
        uart_puts("failed — continuing without MMU\n");
    }

    uart_puts("[4/7] Timer: ");
    timer_start();

    /* Poll until first timer tick to verify timer works */
    for (int i = 0; i < 3; i++) {
        uint64_t deadline, now;
        __asm__ volatile("rdtime %0" : "=r"(deadline));
        deadline += TIMER_FREQ;
        while (1) {
            timer_poll();
            if (system_ticks > (uint64_t)i) {
                uart_puts("  Tick ");
                uart_put_dec(system_ticks);
                uart_puts("\n");
                break;
            }
            __asm__ volatile("rdtime %0" : "=r"(now));
            if (now >= deadline) {
                uart_puts("  Timeout\n");
                break;
            }
            __asm__ volatile("wfi");
        }
    }

    uart_puts("[5/7] Kernel ready\n");
    uart_puts("[6/7] SRVM: requires Sage transpilation (see kmain.sage)\n");
    uart_puts("[7/7] Starting shell...\n\n");

    shell_main();

    uart_puts("\nSystem halted.\n");
    while (1)
        __asm__ volatile("wfi");
}
