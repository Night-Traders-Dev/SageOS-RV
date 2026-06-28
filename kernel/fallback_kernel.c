/* kernel/fallback_kernel.c — Fallback C kernel for SageOS-RV
 *
 * This is the minimal C kernel that boots when Sage transpilation
 * is not yet available for bare-metal. It demonstrates the boot
 * chain works and provides a platform for testing.
 *
 * As SageLang's bare-metal code generation matures, this file
 * will be replaced by transpiled Sage code.
 */

#include <stdint.h>
#include "sbi.h"

/* Forward declarations for freestanding */
typedef uint64_t size_t;
static int strncmp(const char *a, const char *b, int n);
static size_t strlen(const char *s);

/* Volatile tick counter updated by timer interrupt */
static volatile uint64_t system_ticks = 0;

/* UART registers (16550A) */
#define UART_BASE   0x10000000UL
#define UART_THR    0
#define UART_RBR    0
#define UART_IER    1
#define UART_FCR    2
#define UART_LCR    3
#define UART_LSR    5
#define UART_LSR_THRE 0x20
#define UART_LSR_DR   0x01

/* Timer frequency (from OpenSBI: aclint-mtimer @ 10000000Hz) */
#define TIMER_FREQ 10000000UL

/* Memory-mapped I/O helpers (byte accesses for 8250 UART) */
static inline void mmio_write(uint64_t addr, uint8_t val) {
    *(volatile uint8_t *)addr = val;
}

static inline uint8_t mmio_read(uint64_t addr) {
    return *(volatile uint8_t *)addr;
}

/* UART functions */
static void uart_init(void) {
    mmio_write(UART_BASE + UART_IER, 0);     /* Disable interrupts */
    mmio_write(UART_BASE + UART_FCR, 0xC7);  /* Enable FIFO, clear, 14-byte threshold */
    mmio_write(UART_BASE + UART_LCR, 0x03);  /* 8N1 */
}

static void uart_putc(char c) {
    while ((mmio_read(UART_BASE + UART_LSR) & UART_LSR_THRE) == 0)
        ;
    mmio_write(UART_BASE + UART_THR, (uint8_t)c);
}

static void uart_puts(const char *s) {
    while (*s) {
        if (*s == '\n')
            uart_putc('\r');
        uart_putc(*s++);
    }
}

static int uart_getchar(void) {
    if (mmio_read(UART_BASE + UART_LSR) & UART_LSR_DR)
        return mmio_read(UART_BASE + UART_RBR);
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

/* Simple memory statistics */
#define MEM_BASE  0x80200000UL
#define MEM_SIZE  (128UL * 1024 * 1024)
#define PAGE_SIZE 4096UL

static uint64_t total_pages;
static uint64_t free_pages;

static void pmm_init(void) {
    total_pages = MEM_SIZE / PAGE_SIZE;
    free_pages = total_pages - 256; /* Reserve kernel pages */
}

/* Shell */
static int shell_running = 1;

static void cmd_help(void) {
    uart_puts("SageOS-RV Shell Commands:\n");
    uart_puts("  help       Show this help\n");
    uart_puts("  version    Show kernel version\n");
    uart_puts("  mem        Show memory statistics\n");
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
    uart_puts("Build: fallback C kernel (Sage transpilation pending)\n\n");
}

static void cmd_mem(void) {
    uart_puts("Memory Statistics:\n");
    uart_puts("  Total pages: ");
    uart_put_dec(total_pages);
    uart_puts("\n  Free pages:  ");
    uart_put_dec(free_pages);
    uart_puts("\n  Used pages:  ");
    uart_put_dec(total_pages - free_pages);
    uart_puts("\n  Total KB:    ");
    uart_put_dec(total_pages * 4);
    uart_puts("\n  Free KB:     ");
    uart_put_dec(free_pages * 4);
    uart_puts("\n\n");
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
    uart_puts("This is the canonical demonstration that SageLang\n");
    uart_puts("can build a complete software stack from bare metal\n");
    uart_puts("to applications.\n\n");
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
        sbi_set_timer(time + TIMER_FREQ / 2);
    }
}

/* Start the periodic SBI timer */
static void timer_start(void) {
    uint64_t time;
    __asm__ volatile("rdtime %0" : "=r"(time));
    sbi_set_timer(time + TIMER_FREQ / 2);
    __asm__ volatile("csrs sie, %0" :: "r"(0x20));
    uart_puts("  Timer: SBI @ 10MHz, 500ms\n");
}

/* Kernel main — called from boot.S */
void sage_kernel_main(void) {
    uart_init();

    uart_puts("\n");
    uart_puts("========================================\n");
    uart_puts("  SageOS-RV v0.1.0-alpha\n");
    uart_puts("  Pure Sage Operating System\n");
    uart_puts("  RISC-V 64 | QEMU virt\n");
    uart_puts("========================================\n\n");

    uart_puts("[1/6] Console initialized\n");

    pmm_init();
    uart_puts("[2/6] Memory: ");
    uart_put_dec(total_pages);
    uart_puts(" pages (");
    uart_put_dec(MEM_SIZE / 1024);
    uart_puts(" KB)\n");

    uart_puts("[3/6] Starting timer...\n");
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

    uart_puts("[4/6] Device tree (stub)\n");
    uart_puts("[5/6] Starting shell...\n\n");

    shell_main();

    uart_puts("\nSystem halted.\n");
    while (1)
        __asm__ volatile("wfi");
}
