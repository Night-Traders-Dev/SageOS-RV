/* kernel/fallback_kernel.c — Fallback C kernel for SageOS-RV
 *
 * This is the minimal C kernel that boots when Sage transpilation
 * is not yet available for bare-metal. It demonstrates the boot
 * chain works and provides a platform for testing.
 *
 * Shell dispatch:
 *   - If shell.sgvm is embedded (linker section .sgvm_shell, symbols
 *     _shell_sgvm_start / _shell_sgvm_end from linker.ld) the shell
 *     is executed by MetalVM (sage_metal_vm_exec).
 *   - Otherwise the built-in C shell runs as a fallback.
 */

#include <stdint.h>
#include "sbi.h"
#include "dtb.h"
#include "vmm.h"

/* MetalVM glue — provided by metal_vm_glue.c.
 * If SAGE_METAL_VM is not defined the stubs below are used instead. */
#ifdef SAGE_METAL_VM
extern void     sage_metal_vm_init(void);
extern int      sage_metal_vm_exec(const uint8_t *bytecode, uint32_t len);
#else
static inline void sage_metal_vm_init(void) {}
static inline int  sage_metal_vm_exec(const uint8_t *b, uint32_t l)
    { (void)b; (void)l; return -1; }
#endif

/* Linker symbols for the embedded shell.sgvm blob.
 * Defined in boot/arch/rv64/linker.ld via the .sgvm_shell section.
 * objcopy --rename-section .data=.sgvm_shell places the blob there;
 * the linker script emits _shell_sgvm_start and _shell_sgvm_end.
 * When the sentinel empty object was linked (shell.sgvm absent)
 * start == end (zero span). */
extern const uint8_t _shell_sgvm_start[] __attribute__((weak));
extern const uint8_t _shell_sgvm_end[]   __attribute__((weak));

/* Forward declarations for freestanding */
typedef uint64_t size_t;
static int   strncmp(const char *a, const char *b, int n);
static size_t strlen(const char *s);

/* Volatile tick counter updated by timer interrupt */
static volatile uint64_t system_ticks = 0;

/* DTB-discovered hardware info (populated at boot) */
static dtb_info_t hw;

/* UART registers (16550A) */
#define UART_THR      0
#define UART_RBR      0
#define UART_IER      1
#define UART_FCR      2
#define UART_LCR      3
#define UART_LSR      5
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
    mmio_write(base + UART_IER, 0);
    mmio_write(base + UART_FCR, 0xC7);
    mmio_write(base + UART_LCR, 0x03);
}

void uart_putc(char c) {
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

int uart_getchar(void) {
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
            uart_putc(nibble < 10 ? '0' + nibble : 'A' + nibble - 10);
            started = 1;
        }
    }
}

static void uart_put_dec(uint64_t val) {
    if (val == 0) { uart_putc('0'); return; }
    char buf[20];
    int pos = 19;
    buf[pos--] = '\0';
    while (val > 0) { buf[pos--] = '0' + (val % 10); val /= 10; }
    uart_puts(&buf[pos + 1]);
}

/* Memory manager — bitmap-based, 1 bit per 4K page */
#define PAGE_SIZE  4096UL
#define PAGE_SHIFT 12

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
    bitmap[page_idx / 64] &= ~(1ULL << (page_idx % 64));
    free_pages--;
}

static void pmm_mark_free(uint64_t page_idx) {
    bitmap[page_idx / 64] |= (1ULL << (page_idx % 64));
    free_pages++;
}

static void pmm_init(void) {
    mem_base    = hw.mem_base ? hw.mem_base : 0x80200000UL;
    mem_size    = hw.mem_size ? hw.mem_size : (128UL * 1024 * 1024);
    total_pages = mem_size / PAGE_SIZE;
    free_pages  = total_pages;
    bitmap_words = (total_pages + 63) / 64;
    bitmap = (uint64_t *)(uint64_t)_heap_start;
    for (uint64_t i = 0; i < bitmap_words; i++) bitmap[i] = ~0ULL;
    uint64_t kernel_pages = 256;
    uint64_t bitmap_pages = (bitmap_words * 8 + PAGE_SIZE - 1) / PAGE_SIZE;
    for (uint64_t i = 0; i < kernel_pages + bitmap_pages; i++)
        pmm_mark_used(i);
}

uint64_t pmm_alloc(void) {
    if (free_pages == 0) return 0;
    for (uint64_t w = 0; w < bitmap_words; w++) {
        uint64_t word = bitmap[w];
        if (!word) continue;
        uint64_t bit = 0;
        while ((word & 1) == 0) { word >>= 1; bit++; }
        uint64_t idx = w * 64 + bit;
        if (idx < total_pages) { pmm_mark_used(idx); return mem_base + idx * PAGE_SIZE; }
    }
    return 0;
}

static void pmm_free(uint64_t addr) {
    uint64_t idx = (addr - mem_base) / PAGE_SIZE;
    if (idx < total_pages) pmm_mark_free(idx);
}

/* ---------------------------------------------------------------------------
 * shell.sgvm blob helpers — use linker.ld symbols, NOT objcopy auto-names
 * ---------------------------------------------------------------------------
 * linker.ld defines:
 *   _shell_sgvm_start = .;   (before KEEP(*(.sgvm_shell)))
 *   _shell_sgvm_end   = .;   (after)
 * When the sentinel empty object was linked both are equal (zero span).
 * Blobs < 8 bytes are treated as absent.
 * --------------------------------------------------------------------------- */
static const uint8_t *sgvm_shell_data(void) {
    if (!&_shell_sgvm_start || !&_shell_sgvm_end) return 0;
    return _shell_sgvm_start;
}

static uint32_t sgvm_shell_size(void) {
    if (!&_shell_sgvm_start || !&_shell_sgvm_end) return 0;
    uint64_t sz = (uint64_t)_shell_sgvm_end - (uint64_t)_shell_sgvm_start;
    return (sz > 8) ? (uint32_t)sz : 0;
}

/* ---------------------------------------------------------------------------
 * Built-in C shell (runs when shell.sgvm is absent)
 * --------------------------------------------------------------------------- */
static int shell_running = 1;

static void cmd_help(void) {
    uart_puts("SageOS-RV Shell Commands:\n");
    uart_puts("  help        Show this help\n");
    uart_puts("  version     Show kernel version\n");
    uart_puts("  mem         Show memory statistics\n");
    uart_puts("  srvm        VM status\n");
    uart_puts("  clear       Clear screen\n");
    uart_puts("  uptime      Show system uptime\n");
    uart_puts("  reboot      Cold reboot the system\n");
    uart_puts("  poweroff    Shut down the system\n");
    uart_puts("  halt        Halt the CPU (WFI loop)\n");
    uart_puts("  about       About SageOS\n");
    uart_puts("  echo <text> Print text\n\n");
}

static void cmd_version(void) {
    uart_puts("SageOS-RV v0.1.0-alpha\n");
    uart_puts("Kernel: SageOS-RV  Arch: RISC-V 64 (rv64imac)  SBI: v3.0\n");
    const uint8_t *blob = sgvm_shell_data();
    uint32_t       bsz  = sgvm_shell_size();
    uart_puts(bsz > 0 ? "Shell:  shell.sgvm via MetalVM\n\n"
                      : "Shell:  built-in C fallback\n\n");
    (void)blob;
}

static void cmd_mem(void) {
    uint64_t used = total_pages - free_pages;
    uart_puts("Memory Statistics:\n  Base:  "); uart_put_hex(mem_base);
    uart_puts("\n  Size:  "); uart_put_dec(mem_size / 1024); uart_puts(" KB\n");
    uart_puts("  Total pages: "); uart_put_dec(total_pages);
    uart_puts("\n  Free pages:  "); uart_put_dec(free_pages);
    uart_puts("\n  Used pages:  "); uart_put_dec(used);
    uart_puts(" ("); uart_put_dec(used * 100 / total_pages); uart_puts("%)\n");
    uart_puts("  Free KB:     "); uart_put_dec(free_pages * 4); uart_puts("\n\n");
}

static void cmd_srvm(void) {
    uint32_t bsz = sgvm_shell_size();
    uart_puts("SageOS VM status:\n");
    if (bsz > 0) {
        uart_puts("  shell.sgvm : embedded, "); uart_put_dec(bsz);
        uart_puts(" bytes, MetalVM (bare-metal, libc-free)\n");
        uart_puts("  kmain.sgvm : compiled via sagevm --riscv\n");
        uart_puts("  Runtime:     MetalVM (metal_vm.c / metal_rv64_vm.c)\n\n");
    } else {
        uart_puts("  shell.sgvm : not embedded\n");
        uart_puts("  Action: ./sagemake compile-shell && ./sagemake build\n\n");
    }
}

static void cmd_clear(void)   { uart_puts("\033[2J\033[H"); }
static void cmd_uptime(void)  {
    uart_puts("Uptime: "); uart_put_dec(system_ticks);
    uart_puts(" ticks (500ms each)\n");
}
static void cmd_about(void) {
    uart_puts("SageOS-RV -- A Pure Sage Operating System\n");
    uart_puts("Target: LicheeRV Nano (Sophgo SG2002, RISC-V 64)\n");
    uart_puts("VM:     MetalVM (bare-metal, libc-free, RV64 bytecode)\n\n");
}

static void process_command(const char *line) {
    if (!line[0]) return;
    const char *cmd = line, *args = line;
    while (*args && *args != ' ') args++;
    int n = args - cmd;
    if (*args == ' ') args++;

    if      (strncmp(cmd,"help",n)==0&&n==4)     cmd_help();
    else if (strncmp(cmd,"version",n)==0&&n==7)  cmd_version();
    else if (strncmp(cmd,"mem",n)==0&&n==3)      cmd_mem();
    else if (strncmp(cmd,"srvm",n)==0&&n==4)     cmd_srvm();
    else if (strncmp(cmd,"clear",n)==0&&n==5)    cmd_clear();
    else if (strncmp(cmd,"uptime",n)==0&&n==6)   cmd_uptime();
    else if (strncmp(cmd,"about",n)==0&&n==5)    cmd_about();
    else if (strncmp(cmd,"reboot",n)==0&&n==6)   { uart_puts("Rebooting...\n"); sbi_cold_reboot(); }
    else if (strncmp(cmd,"poweroff",n)==0&&n==8) { uart_puts("Powering off...\n"); sbi_shutdown(); }
    else if (strncmp(cmd,"halt",n)==0&&n==4)     { uart_puts("Halting...\n"); shell_running=0; }
    else if (strncmp(cmd,"echo",n)==0&&n==4)     { uart_puts(args); uart_puts("\n"); }
    else uart_puts("Unknown command. Type 'help'.\n");
}

static int strncmp(const char *a, const char *b, int n) {
    for (int i=0;i<n;i++) { if(a[i]!=b[i]) return a[i]-b[i]; if(!a[i]) return 0; }
    return 0;
}
static size_t strlen(const char *s) { size_t l=0; while(s[l]) l++; return l; }

static int use_sstc = 0;

static void timer_arm(uint64_t deadline) {
    if (use_sstc) __asm__ volatile("csrw 0x14D, %0" :: "r"(deadline));
    else          sbi_set_timer(deadline);
}

static void timer_poll(void);

static int console_getchar(void) {
    int c = uart_getchar();
    return (c >= 0) ? c : sbi_console_getchar();
}

static void shell_main(void) {
    uart_puts("SageOS-RV Shell (type 'help' for commands)\n\n");
    char buf[256];
    while (shell_running) {
        timer_poll();
        uart_puts("sage# ");
        int pos = 0; buf[0] = '\0';
        while (1) {
            int c = -1;
            for (int t=0;t<1000;t++) { c=console_getchar(); if(c>=0) break; timer_poll(); }
            if (c<0) { timer_poll(); continue; }
            if (c=='\r'||c=='\n') { uart_putc('\r'); uart_putc('\n'); buf[pos]='\0'; break; }
            else if (c==0x7F||c=='\b') { if(pos>0){pos--;buf[pos]='\0';uart_putc('\b');uart_putc(' ');uart_putc('\b');} }
            else if (c>=32&&c<127) { if(pos<255) buf[pos++]=(char)c, uart_putc((char)c); }
        }
        process_command(buf);
    }
}

static void timer_poll(void) {
    uint64_t sip;
    __asm__ volatile("csrr %0, sip" : "=r"(sip));
    if (sip & 0x20) {
        system_ticks++;
        uint64_t t; __asm__ volatile("rdtime %0" : "=r"(t));
        timer_arm(t + TIMER_FREQ / 2);
    }
}

static void timer_start(void) {
    uint64_t t; __asm__ volatile("rdtime %0" : "=r"(t));
    uint64_t probe = 0xAAAA5555AAAA5555UL, rb = 0;
    __asm__ volatile("csrw 0x14D,%1\n\tcsrr %0,0x14D" : "=r"(rb) : "r"(probe) : "memory");
    if (rb == probe) {
        use_sstc = 1;
        timer_arm(t + TIMER_FREQ / 2);
        uart_puts("stimecmp @ "); uart_put_dec(TIMER_FREQ/1000000); uart_puts(" MHz, 500ms\n");
    } else {
        timer_arm(t + TIMER_FREQ / 2);
        uart_puts("SBI @ "); uart_put_dec(TIMER_FREQ/1000000); uart_puts(" MHz, 500ms\n");
    }
    __asm__ volatile("csrs sie, %0" :: "r"(0x20));
}

/* ---------------------------------------------------------------------------
 * sage_kernel_main — called from boot.S
 * a0 = hart_id, a1 = DTB address (OpenSBI S-mode convention)
 * --------------------------------------------------------------------------- */
void sage_kernel_main(uint64_t hart_id, uint64_t dtb_addr) {
    uart_init();
    uart_puts("\n========================================\n");
    uart_puts("  SageOS-RV v0.1.0-alpha\n");
    uart_puts("  Pure Sage Operating System\n");
    uart_puts("  RISC-V 64 | QEMU virt\n");
    uart_puts("========================================\n\n");

    uart_puts("[1/7] Console initialized\n");
    int dtb_ok = dtb_parse(dtb_addr, &hw);
    if (dtb_ok == 0) {
        uart_puts("  DTB: "); uart_put_hex(hw.mem_size/1024);
        uart_puts(" KB @ "); uart_put_hex(hw.mem_base);
        uart_puts(", timer "); uart_put_dec(hw.timer_freq/1000000); uart_puts(" MHz\n");
        uart_puts("       UART @ "); uart_put_hex(hw.uart_base);
        uart_puts(", PLIC @ "); uart_put_hex(hw.plic_base);
        uart_puts(", CPUs "); uart_put_dec(hw.cpu_count); uart_puts("\n");
    } else {
        uart_puts("  DTB: fallback defaults\n");
    }
    uart_init();

    uart_puts("[2/7] Memory: ");
    pmm_init();
    uart_put_dec(total_pages); uart_puts(" pages (");
    uart_put_dec(mem_size/1024); uart_puts(" KB) — ");
    uart_put_dec(bitmap_words); uart_puts(" bitmap words\n");

    uart_puts("[3/7] VMM: ");
    int vmm_ok = vmm_init();
    if (vmm_ok == 0) {
        vmm_identity_map(0x80200000UL, 0x81000000UL, PTE_R|PTE_W|PTE_X|PTE_G);
        vmm_identity_map(hw.uart_base, hw.uart_base+0x1000, PTE_R|PTE_W|PTE_G);
        if (hw.plic_base)
            vmm_identity_map(hw.plic_base, hw.plic_base+0x400000, PTE_R|PTE_W|PTE_G);
        vmm_activate();
        uart_puts("SV39 active\n");
    } else {
        uart_puts("failed — continuing without MMU\n");
    }

    uart_puts("[4/7] Timer: ");
    timer_start();
    for (int i=0;i<3;i++) {
        uint64_t dl,now;
        __asm__ volatile("rdtime %0" : "=r"(dl)); dl += TIMER_FREQ;
        while (1) {
            timer_poll();
            if (system_ticks>(uint64_t)i) {
                uart_puts("  Tick "); uart_put_dec(system_ticks); uart_puts("\n"); break;
            }
            __asm__ volatile("rdtime %0" : "=r"(now));
            if (now>=dl) { uart_puts("  Timeout\n"); break; }
            __asm__ volatile("wfi");
        }
    }

    uart_puts("[5/7] Kernel ready\n");

    /* [6/7] MetalVM init */
    {
        uint32_t bsz = sgvm_shell_size();
        if (bsz > 0) {
            uart_puts("[6/7] MetalVM: shell.sgvm embedded (");
            uart_put_dec(bsz); uart_puts(" bytes)\n");
            sage_metal_vm_init();
        } else {
            uart_puts("[6/7] MetalVM: shell.sgvm absent — C shell fallback\n");
        }
    }

    uart_puts("[7/7] Starting shell...\n\n");

    /* [7/7] Shell dispatch */
    {
        const uint8_t *blob = sgvm_shell_data();
        uint32_t       bsz  = sgvm_shell_size();
        if (blob && bsz > 0) {
            int rc = sage_metal_vm_exec(blob, bsz);
            if (rc != 0) {
                uart_puts("MetalVM exited (rc=");
                uart_put_dec(rc < 0 ? (uint64_t)-rc : (uint64_t)rc);
                uart_puts(") — falling back to C shell\n\n");
                shell_main();
            }
        } else {
            shell_main();
        }
    }

    uart_puts("\nSystem halted.\n");
    while (1) __asm__ volatile("wfi");
}
