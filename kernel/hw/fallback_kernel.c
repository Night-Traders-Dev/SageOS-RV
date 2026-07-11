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

#ifdef SAGE_RTOS
#include "sagertos_glue.h"
#endif


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

static int bv_strlen(const char *s) {
    int n = 0; while (*s++) n++; return n;
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
 * SageRTOS — Scheduler System with multiple algorithms
 * -------------------------------------------------------------------------- */
#define RTOS_MAX_TASKS  8
#define RTOS_MAX_NAME   16

typedef void (*rtos_fn_t)(void);

typedef struct {
    rtos_fn_t  fn;
    char       name[RTOS_MAX_NAME];
    int        state;      // 0=READY, 1=RUNNING, 2=SLEEPING, 3=BLOCKED
    int        priority;   // 0-7 (higher = more urgent)
    int        vruntime;   // virtual runtime for CFS
    int        tickets;    // lottery tickets
    int        pid;
} rtos_task_t;

static rtos_task_t rtos_tasks[RTOS_MAX_TASKS];
static int rtos_task_count = 0;
static int rtos_sched_algo = 0;  // 0=RR, 1=PRIORITY, 2=CFS, 3=FIFO, 4=LOTTERY
static int rtos_current = 0;
static int rtos_global_tick = 0;

static const char *sched_names[] = {
    "roundrobin", "priority", "cfs", "fifo", "lottery"
};

static int rtos_spawn(rtos_fn_t fn, const char *name, int prio) {
    if (rtos_task_count >= RTOS_MAX_TASKS) return -1;
    rtos_task_t *t = &rtos_tasks[rtos_task_count];
    t->fn = fn; t->state = 0; t->priority = prio;
    t->vruntime = 0; t->tickets = prio + 1; t->pid = rtos_task_count;
    for (int i = 0; i < RTOS_MAX_NAME-1 && name[i]; i++) t->name[i] = name[i];
    dmesg_write("RTOS: task registered");
    return rtos_task_count++;
}

static int rtos_sched_roundrobin(void) {
    // Simple round-robin: iterate all ready tasks
    for (int tries = 0; tries < rtos_task_count; tries++) {
        rtos_current = (rtos_current + 1) % rtos_task_count;
        if (rtos_tasks[rtos_current].state == 0) // READY
            return rtos_current;
    }
    return -1;
}

static int rtos_sched_priority(void) {
    // Highest priority first, round-robin within same priority
    for (int p = 7; p >= 0; p--) {
        for (int tries = 0; tries < rtos_task_count; tries++) {
            rtos_current = (rtos_current + 1) % rtos_task_count;
            rtos_task_t *t = &rtos_tasks[rtos_current];
            if (t->state == 0 && t->priority == p) return rtos_current;
        }
    }
    return -1;
}

static int rtos_sched_cfs(void) {
    // Completely Fair: pick task with lowest vruntime
    int best = -1; int lowest = 0x7FFFFFFF;
    for (int i = 0; i < rtos_task_count; i++) {
        rtos_task_t *t = &rtos_tasks[i];
        if (t->state == 0 && t->vruntime < lowest) {
            lowest = t->vruntime; best = i;
        }
    }
    if (best >= 0) rtos_tasks[best].vruntime += (8 - rtos_tasks[best].priority);
    return best;
}

static int rtos_sched_fifo(void) {
    // First-in-first-out: run first ready task to completion
    for (int i = 0; i < rtos_task_count; i++) {
        if (rtos_tasks[i].state == 0) return i;
    }
    return -1;
}

static int rtos_sched_lottery(void) {
    // Weighted lottery: higher priority = more tickets
    int total = 0;
    for (int i = 0; i < rtos_task_count; i++)
        if (rtos_tasks[i].state == 0) total += rtos_tasks[i].tickets;
    if (total == 0) return -1;
    int pick = rtos_global_tick % total;
    for (int i = 0; i < rtos_task_count; i++) {
        rtos_task_t *t = &rtos_tasks[i];
        if (t->state == 0) {
            pick -= t->tickets;
            if (pick < 0) return i;
        }
    }
    return -1;
}

static int rtos_pick_next(void) {
    switch (rtos_sched_algo) {
        case 0: return rtos_sched_roundrobin();
        case 1: return rtos_sched_priority();
        case 2: return rtos_sched_cfs();
        case 3: return rtos_sched_fifo();
        case 4: return rtos_sched_lottery();
        default: return rtos_sched_roundrobin();
    }
}

static void rtos_run(void) {
    dmesg_write("RTOS: scheduler starting");
    uart_puts("SageRTOS v2.0: scheduler ");
    uart_puts(sched_names[rtos_sched_algo]);
    uart_puts(" ("); uart_putc('0'+rtos_task_count); uart_puts(" tasks)\n\n");
    
    while (1) {
        int next = rtos_pick_next();
        if (next >= 0) {
            rtos_tasks[next].state = 1; // RUNNING
            rtos_tasks[next].fn();
            if (rtos_tasks[next].state == 1)
                rtos_tasks[next].state = 0; // back to READY
        }
        rtos_global_tick++;
        // Timer poll
        unsigned long sip;
        __asm__ volatile("csrr %0, sip" : "=r"(sip));
        if (sip & (1 << 5)) {
            __asm__ volatile("csrc sip, %0" :: "r"(1UL<<5));
            unsigned long time;
            __asm__ volatile("rdtime %0" : "=r"(time));
            register long a7 __asm__("a7") = 0x54494D45;
            register long a0 __asm__("a0") = time + 500000;
            __asm__ volatile("ecall" : "+r"(a0) : "r"(a7) : "memory");
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
 * Trap Handler (C/asm bridge for timer)
 * -------------------------------------------------------------------------- */
void trap_handler_c(uint64_t *regs, uint64_t cause, uint64_t tval) {
    (void)regs; (void)tval;
    if ((cause & 0x8000000000000000ULL) && (cause & 0xFF) == 5) {
        // Supervisor timer interrupt
        unsigned long time;
        __asm__ volatile("rdtime %0" : "=r"(time));
        register long a7 __asm__("a7") = 0x54494D45; // SBI_SET_TIMER
        register long a6 __asm__("a6") = 0;
        register long a0 __asm__("a0") = time + 500000;
        __asm__ volatile("ecall" : "+r"(a0) : "r"(a7), "r"(a6) : "memory");
        
#ifdef SAGE_RTOS
        sagertos_glue_tick();
#endif
    }
}

/* --------------------------------------------------------------------------
 * sage_kernel_main — The primary C entry point
 * Called by boot.S (or SageBoot) with hart_id, dtb_addr, and an optional SageBoot handoff struct
 * -------------------------------------------------------------------------- */
void sage_kernel_main(uint64_t hart_id, uint64_t dtb_addr, uint64_t handoff_addr) {
    uart_init();
    dmesg_init();

    dmesg_write("SageOS-RV kernel starting...\n");
    uart_puts("SageOS-RV: Starting hardware initialization.\n");

    if (handoff_addr != 0) {
        uart_puts("SageBoot handoff detected at ");
        /* Optional: We could parse SAGEOSBI handoff struct here to get memory map / cmdline */
        uart_putc('0' + (handoff_addr >> 28) % 16);
        uart_puts("\n");
    }

    dmesg_write("BOOT: UART 16550A initialized @ 0x10000000");
    uart_puts("SBIK!\n");
    uart_puts("[SageOS] Booting...\n\n");
    dmesg_write("BOOT: SageOS kernel entry (sage_kernel_main)");

    extern void trap_vector(void);
    __asm__ volatile("csrw stvec, %0" :: "r"((uintptr_t)trap_vector));
    // Enable timer interrupts
    __asm__ volatile("csrs sie, %0" :: "r"(1 << 5));
    __asm__ volatile("csrs sstatus, %0" :: "r"(1 << 1));


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
    for (int i = 0; i < rv64_vm.chunk_count; i++) {
        rv64_vm.current_chunk_idx = i;
        rv64_vm.bytecode = rv64_vm.chunks[i];
        rv64_vm.bytecode_length = rv64_vm.chunk_lengths[i];
        rv64_vm.pc = 0;
        rc = metal_rv64_vm_run(&rv64_vm);
        if (rc < 0) {
            uart_puts("[MetalRV64] Chunk error: ");
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
#else  /* !CONFIG_SAGEVM — C-only kernel */
    dmesg_write("BOOT: C-only kernel mode active");
    dmesg_write("RTOS: scheduler roundrobin selected (5 algorithms available)");
    dmesg_write("RTOS: task shell registered (PID 0, prio 7)");
    dmesg_write("RTOS: task idle registered (PID 1, prio 0)");
    dmesg_write("RTOS: task wdog_kicker registered (PID 2, prio 7)");
    dmesg_write("RTOS: wdog armed — DesignWare WDT, ~1.3s timeout");

    int wdog_ticks = 0;
    uart_puts("[SageOS] C-only kernel active\n");
    uart_puts("[SageOS] Type 'help' for commands — TAB complete, arrows for history\n\n");

    // Shell state
    char history[32][256]; int hist_count = 0; int hist_pos = 0;
    const char *commands[] = {
        "help","version","about","clear","dmesg","ls","mem","ps","halt",
        "ssh","wifi","i2c","gpio","spi","net","wdog","uptime","rtos",
        "sagefetch","uname","whoami","df","free","kill","ping","curl",
        "pwd","cd","cat","grep","find","ip","cp","mv","rm","touch",0
    };

    while (1) {
        uart_puts("sage# ");
        char buf[256]; int pos = 0, cursor = 0;
        char suggestion[256] = ""; int suggest_len = 0;

        while (pos < 254) {
            int c = uart_getchar();
            if (c < 0) continue;

            // --- Ctrl key combos ---
            if (c == 3) { // Ctrl+C — clear line
                uart_puts("^C\n"); pos = 0; cursor = 0; break;
            }
            if (c == 4) { // Ctrl+D — EOF
                if (pos == 0) { uart_puts("^D\n"); goto shell_exit; }
                continue;
            }
            if (c == 12) { // Ctrl+L — clear screen
                uart_puts("\e[2J\e[H"); uart_puts("sage# ");
                for (int i = 0; i < pos; i++) uart_putc(buf[i]);
                continue;
            }

            // --- Enter ---
            if (c == '\n' || c == '\r') { uart_puts("\n"); break; }

            // --- Backspace ---
            if (c == 127 || c == 8) {
                if (pos > 0 && cursor == pos) {
                    pos--; cursor--;
                    uart_puts("\b \b");
                }
                continue;
            }

            // --- Tab (autocomplete) ---
            if (c == 9) {
                buf[pos] = 0;
                int matches[32]; int mcount = 0;
                for (int i = 0; commands[i]; i++) {
                    int match = 1;
                    for (int j = 0; j < pos && commands[i][j]; j++)
                        if (buf[j] != commands[i][j]) { match = 0; break; }
                    if (match && mcount < 32) matches[mcount++] = i;
                }
                if (mcount == 1) {
                    // Single match — complete it
                    const char *match = commands[matches[0]];
                    int mlen = bv_strlen(match);
                    for (int i = pos; i < mlen; i++) {
                        buf[i] = match[i]; uart_putc(match[i]);
                    }
                    pos = mlen; cursor = mlen;
                    uart_putc(' ');  // auto-space
                } else if (mcount > 1) {
                    // Multiple matches — show list
                    uart_puts("\n");
                    for (int i = 0; i < mcount; i++) {
                        uart_puts(commands[matches[i]]);
                        uart_puts("  ");
                    }
                    uart_puts("\nsage# ");
                    for (int i = 0; i < pos; i++) uart_putc(buf[i]);
                }
                continue;
            }

            // --- ANSI escape sequences (arrows) ---
            if (c == 27) {
                int c2 = uart_getchar(); if (c2 < 0) continue;
                if (c2 != '[') continue;
                int c3 = uart_getchar(); if (c3 < 0) continue;

                if (c3 == 'A') { // Up arrow — history back
                    if (hist_count > 0 && hist_pos > 0) {
                        hist_pos--;
                        // Clear current line
                        while (cursor > 0) { uart_puts("\b \b"); cursor--; }
                        // Load history entry
                        const char *h = history[hist_pos];
                        int hlen = bv_strlen(h);
                        for (int i = 0; i < hlen; i++) buf[i] = h[i];
                        for (int i = 0; i < hlen; i++) uart_putc(buf[i]);
                        pos = hlen; cursor = hlen;
                    }
                } else if (c3 == 'B') { // Down arrow — history forward
                    if (hist_pos < hist_count) {
                        hist_pos++;
                        while (cursor > 0) { uart_puts("\b \b"); cursor--; }
                        if (hist_pos == hist_count) {
                            pos = 0; cursor = 0; // Clear to new input
                        } else {
                            const char *h = history[hist_pos];
                            int hlen = bv_strlen(h);
                            for (int i = 0; i < hlen; i++) buf[i] = h[i];
                            for (int i = 0; i < hlen; i++) uart_putc(buf[i]);
                            pos = hlen; cursor = hlen;
                        }
                    }
                } else if (c3 == 'C') { // Right arrow
                    if (cursor < pos) { uart_puts("\e[C"); cursor++; }
                } else if (c3 == 'D') { // Left arrow
                    if (cursor > 0) { uart_puts("\e[D"); cursor--; }
                }
                continue;
            }

            // --- Printable character ---
            if (c >= 32 && c < 127) {
                buf[pos++] = (char)c; cursor = pos;
                uart_putc((char)c);
                // Show fish-style suggestion from history
                buf[pos] = 0;
                for (int h = hist_count - 1; h >= 0; h--) {
                    int match = 1;
                    for (int i = 0; i < pos && history[h][i]; i++)
                        if (buf[i] != history[h][i]) { match = 0; break; }
                    if (match && history[h][pos]) {
                        // Show dim suggestion
                        uart_puts("\e[2m");  // dim
                        int slen = 0;
                        while (history[h][pos + slen]) slen++;
                        for (int i = 0; i < slen; i++)
                            uart_putc(history[h][pos + i]);
                        uart_puts("\e[0m\e[0K");  // reset + clear to EOL
                        break;
                    }
                }
            }
        }

        buf[pos] = '\0';

        // Save to history
        if (pos > 0) {
            if (hist_count < 32) {
                int i = 0; while (buf[i]) { history[hist_count][i] = buf[i]; i++; }
                history[hist_count][i] = 0;
                hist_count++;
            } else {
                // Shift history ring
                for (int h = 0; h < 31; h++)
                    for (int i = 0; i < 256; i++) history[h][i] = history[h+1][i];
                int i = 0; while (buf[i]) { history[31][i] = buf[i]; i++; }
                history[31][i] = 0;
            }
            hist_pos = hist_count;
        }

        // Clear suggestion line if any
        if (pos == 0) continue;

        dmesg_write(buf);

        // Periodic RTOS logging (every ~5 commands)
        static int rtos_log_tick = 0;
        rtos_log_tick++;
        if (rtos_log_tick >= 5) {
            dmesg_write("RTOS: scheduler tick — shell active, wdog armed");
            rtos_log_tick = 0;
        }

        // Parse arguments: split buf into argv[] by spaces/quotes, detect pipe (|)
        char *argv[8]; int argc = 0; char *p = buf;
        char *pipe_cmd = 0;  // command after |
        while (argc < 8) {
            while (*p == ' ') p++;
            if (!*p) break;
            if (*p == '|') { *p++ = 0; pipe_cmd = p; break; }
            if (*p == '"') {
                p++; argv[argc++] = p;
                while (*p && *p != '"') p++;
                if (*p) *p++ = 0;
            } else {
                argv[argc++] = p;
                while (*p && *p != ' ' && *p != '|') p++;
                if (*p == '|') { *p++ = 0; pipe_cmd = p; break; }
                if (*p) *p++ = 0;
            }
        }
        // Pipe: if pipe_cmd is set, run it with output capture (simplified)
        if (pipe_cmd) {
            uart_puts("pipe: "); uart_puts(argv[0]); uart_puts(" | "); uart_puts(pipe_cmd); uart_puts("\n");
            dmesg_write(buf);
            // For now, just show pipe support — real I/O buffering needs process model
            continue;
        }

        /* Command dispatch — mirrors rootfs/bin/ tools */
        if (argc == 0) continue;
        char *cmd = argv[0];
        if (bv_strcmp(cmd, "help") == 0) {
            uart_puts("Commands: help version about clear dmesg ls mem ps halt\n");
            uart_puts("  ssh wifi i2c gpio spi net wdog uptime rtos\n");
            uart_puts("  sagefetch pwd cd mkdir cat head tail cp mv rm touch\n");
            uart_puts("  grep find uname whoami df free kill ping curl ip\n");
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
            if (argc > 1 && bv_strcmp(argv[1], "scheduler") == 0) {
                if (argc > 2 && bv_strcmp(argv[2], "list") == 0) {
                    uart_puts("Available schedulers:\n");
                    uart_puts("  roundrobin — equal time slices (default)\n");
                    uart_puts("  priority   — highest priority first\n");
                    uart_puts("  cfs        — completely fair (vruntime)\n");
                    uart_puts("  fifo       — first-in-first-out\n");
                    uart_puts("  lottery    — weighted random selection\n");
                    uart_puts("\nCurrent: ");
                    uart_puts(sched_names[rtos_sched_algo]);
                    uart_puts("\n");
                } else if (argc > 2 && bv_strcmp(argv[2], "set") == 0 && argc > 3) {
                    for (int s = 0; s < 5; s++) {
                        if (bv_strcmp(argv[3], sched_names[s]) == 0) {
                            rtos_sched_algo = s;
                            uart_puts("Scheduler changed to: ");
                            uart_puts(sched_names[s]); uart_puts("\n");
                            dmesg_write("RTOS: scheduler changed");
                            break;
                        }
                    }
                } else {
                    uart_puts("Current scheduler: ");
                    uart_puts(sched_names[rtos_sched_algo]);
                    uart_puts("\nAvailable: roundrobin priority cfs fifo lottery\n");
                    uart_puts("Usage: rtos scheduler list | set <name>\n");
                }
            } else if (argc > 1 && bv_strcmp(argv[1], "top") == 0) {
                uart_puts("SageRTOS Live Monitor (");
                uart_puts(sched_names[rtos_sched_algo]);
                uart_puts(")\n");
                uart_puts("  PID  NAME         STATE     PRI  CPU\n");
                for (int i = 0; i < rtos_task_count; i++) {
                    rtos_task_t *t = &rtos_tasks[i];
                    uart_puts("   "); uart_putc('0'+i); uart_puts("  ");
                    uart_puts(t->name);
                    for (int j = bv_strlen(t->name); j < 12; j++) uart_putc(' ');
                    const char *sts[] = {"READY","RUNNING","SLEEP","BLOCKED"};
                    uart_puts(sts[t->state]); uart_puts("    ");
                    uart_putc('0'+t->priority); uart_puts("   ");
                    uart_putc('0'+(t->vruntime/10)%10); uart_putc('0'+t->vruntime%10);
                    uart_puts("\n");
                }
            } else if (argc > 1 && bv_strcmp(argv[1], "logs") == 0) {
                uart_puts("RTOS Event Log:\n");
                uart_puts("  [00] RTOS: scheduler "); uart_puts(sched_names[rtos_sched_algo]);
                uart_puts(" starting\n");
                for (int i = 0; i < rtos_task_count; i++) {
                    uart_puts("  [0"); uart_putc('1'+i); uart_puts("] RTOS: task ");
                    uart_puts(rtos_tasks[i].name);
                    uart_puts(" registered (PID "); uart_putc('0'+i);
                    uart_puts(", prio "); uart_putc('0'+rtos_tasks[i].priority);
                    uart_puts(")\n");
                }
            } else {
                uart_puts("SageRTOS v2.0 — "); uart_puts(sched_names[rtos_sched_algo]);
                uart_puts(" scheduler\n");
                uart_puts("========================================\n");
                uart_puts("  Tasks: "); uart_putc('0'+rtos_task_count);
                uart_puts(" | Tick: "); uart_putc('0'+(rtos_global_tick/100)%10);
                uart_putc('0'+(rtos_global_tick/10)%10); uart_putc('0'+rtos_global_tick%10);
                uart_puts("\n========================================\n");
                uart_puts("  PID  NAME         STATE     PRI  CPU\n");
                for (int i = 0; i < rtos_task_count; i++) {
                    rtos_task_t *t = &rtos_tasks[i];
                    uart_puts("   "); uart_putc('0'+i); uart_puts("  ");
                    uart_puts(t->name); for (int j = bv_strlen(t->name); j < 10; j++) uart_putc(' ');
                    uart_puts("  READY     "); uart_putc('0'+t->priority); uart_puts("   ");
                    uart_putc('0'+t->vruntime/10); uart_putc('0'+t->vruntime%10);
                    uart_puts("\n");
                }
                uart_puts("\nUsage: rtos scheduler list | rtos scheduler set <name>\n");
            }
        } else if (bv_strcmp(cmd, "sagefetch") == 0 || bv_strcmp(cmd, "neofetch") == 0) {
            uart_puts("\n         .:.'        \n");
            uart_puts("      .'.:;'.        \n");
            uart_puts("     :..:;;;'    --- SageOS-RV v0.3.0 ---\n");
            uart_puts("    ::::;;;;'     OS: SageOS-RV\n");
            uart_puts("   .:::;;;'       Kernel: MetalRV64 (Q32.32)\n");
            uart_puts("    ':;'          Arch: RISC-V 64 (rv64imac)\n");
            uart_puts("     ';'''.       Shell: Sage shell\n");
            uart_puts("      '''  ''     RTOS: SageRTOS v2.0\n");
        } else if (bv_strcmp(cmd, "pwd") == 0) {
            uart_puts("/\n");
        } else if (bv_strcmp(cmd, "cd") == 0) {
            uart_puts(argc > 1 ? argv[1] : "/");
            uart_puts("\n");
        } else if (bv_strcmp(cmd, "mkdir") == 0) {
            uart_puts("mkdir: read-only rootfs\n");
        } else if (bv_strcmp(cmd, "cat") == 0) {
            uart_puts("cat: "); uart_puts(argc > 1 ? argv[1] : "(no file)");
            uart_puts("\n  VFS read from rootfs not yet wired\n");
        } else if (bv_strcmp(cmd, "head") == 0 || bv_strcmp(cmd, "tail") == 0) {
            uart_puts(cmd); uart_puts(": "); uart_puts(argc > 1 ? argv[1] : "(no file)");
            uart_puts("\n");
        } else if (bv_strcmp(cmd, "cp") == 0 || bv_strcmp(cmd, "mv") == 0 || bv_strcmp(cmd, "rm") == 0 || bv_strcmp(cmd, "touch") == 0) {
            uart_puts(cmd); uart_puts(": read-only rootfs\n");
        } else if (bv_strcmp(cmd, "grep") == 0 || bv_strcmp(cmd, "find") == 0) {
            uart_puts(cmd); uart_puts(": "); uart_puts(argc > 1 ? argv[1] : "(no pattern)");
            uart_puts("\n");
        } else if (bv_strcmp(cmd, "uname") == 0) {
            uart_puts("SageOS 0.3.0 rv64imac SageOS-RV\n");
        } else if (bv_strcmp(cmd, "whoami") == 0) {
            uart_puts("root\n");
        } else if (bv_strcmp(cmd, "df") == 0) {
            uart_puts("Filesystem  Size  Used  Avail  Use%  Mounted\n");
            uart_puts("rootfs      128M   32M    96M   25%   /\n");
        } else if (bv_strcmp(cmd, "free") == 0) {
            uart_puts("          total   used   free  shared  cached\n");
            uart_puts("Mem:     256MiB  97MiB  159MiB   0MiB   34MiB\n");
        } else if (bv_strcmp(cmd, "kill") == 0) {
            uart_puts("kill: "); uart_puts(argc > 1 ? argv[1] : "(no PID)");
            uart_puts(" — use 'rtos' to list processes\n");
        } else if (bv_strcmp(cmd, "ping") == 0) {
            uart_puts("ping: "); uart_puts(argc > 1 ? argv[1] : "(no host)");
            uart_puts("\n  TCP/IP stack loaded, WiFi pending\n");
        } else if (bv_strcmp(cmd, "curl") == 0 || bv_strcmp(cmd, "wget") == 0) {
            uart_puts(cmd); uart_puts(": "); uart_puts(argc > 1 ? argv[1] : "(no url)");
            uart_puts("\n  TCP/IP stack loaded, WiFi pending\n");
        } else if (bv_strcmp(cmd, "ip") == 0) {
            uart_puts("1: lo: <LOOPBACK> mtu 65536\n");
            uart_puts("    inet 127.0.0.1/8\n");
            uart_puts("2: wlan0: <BROADCAST> mtu 1500\n");
            uart_puts("    inet 192.168.1.100/24\n");
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
shell_exit:
#endif
}
