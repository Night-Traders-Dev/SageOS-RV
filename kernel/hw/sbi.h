/* kernel/sbi.h — RISC-V SBI (Supervisor Binary Interface) wrappers
 *
 * SBI v3.0 standard extensions:
 *   Legacy  (EIDs 0x01-0x08): console, IPI, fence, shutdown
 *   SRST    (EID 0x53525354): system reset
 *   Time    (EID 0x54494D45): timer
 *   DBCN    (EID 0x4442434E): debug console
 */

#ifndef SBI_H
#define SBI_H

#include <stdint.h>

/* SBI extension IDs */
#define SBI_EXT_LEGACY_CONSOLE_PUTCHAR  0x01
#define SBI_EXT_LEGACY_CONSOLE_GETCHAR  0x02
#define SBI_EXT_LEGACY_SHUTDOWN         0x08
#define SBI_EXT_SRST                    0x53525354
#define SBI_EXT_TIME                    0x54494D45
#define SBI_EXT_DBCN                    0x4442434E

/* SRST function IDs */
#define SBI_EXT_SRST_SYSTEM_RESET       0
#define SBI_EXT_TIME_SET_TIMER          0

/* SRST reset types */
#define SBI_SRST_RESET_TYPE_SHUTDOWN    0
#define SBI_SRST_RESET_TYPE_COLD_REBOOT 1
#define SBI_SRST_RESET_TYPE_WARM_REBOOT 2

/* SRST reset reasons */
#define SBI_SRST_RESET_REASON_NONE      0

/* SBI return value */
struct sbi_ret {
    long error;
    long value;
};

/* Make an SBI ecall (legacy calling convention) */
static inline long sbi_ecall_legacy(long ext, long arg0, long arg1, long arg2) {
    register long a0 asm("a0") = arg0;
    register long a1 asm("a1") = arg1;
    register long a2 asm("a2") = arg2;
    register long a7 asm("a7") = ext;
    asm volatile("ecall"
        : "+r"(a0)
        : "r"(a1), "r"(a2), "r"(a7)
        : "memory");
    return a0;
}

/* Make an SBI ecall (standard v3.0 calling convention) */
static inline struct sbi_ret sbi_ecall(long ext, long fid, long arg0, long arg1, long arg2, long arg3, long arg4, long arg5) {
    struct sbi_ret ret;
    register long a0 asm("a0") = arg0;
    register long a1 asm("a1") = arg1;
    register long a2 asm("a2") = arg2;
    register long a3 asm("a3") = arg3;
    register long a4 asm("a4") = arg4;
    register long a5 asm("a5") = arg5;
    register long a6 asm("a6") = fid;
    register long a7 asm("a7") = ext;
    asm volatile("ecall"
        : "+r"(a0), "+r"(a1)
        : "r"(a2), "r"(a3), "r"(a4), "r"(a5), "r"(a6), "r"(a7)
        : "memory");
    ret.error = a0;
    ret.value = a1;
    return ret;
}

/* Legacy: Put a character on the console */
static inline void sbi_console_putchar(int ch) {
    sbi_ecall_legacy(SBI_EXT_LEGACY_CONSOLE_PUTCHAR, ch, 0, 0);
}

/* Legacy: Get a character from the console (non-blocking, returns -1 if none) */
static inline int sbi_console_getchar(void) {
    return (int)sbi_ecall_legacy(SBI_EXT_LEGACY_CONSOLE_GETCHAR, 0, 0, 0);
}

/* SRST: System reset */
static inline void sbi_system_reset(uint32_t reset_type, uint32_t reset_reason) {
    sbi_ecall(SBI_EXT_SRST, SBI_EXT_SRST_SYSTEM_RESET,
              reset_type, reset_reason, 0, 0, 0, 0);
}

/* Shutdown */
static inline void sbi_shutdown(void) {
    sbi_system_reset(SBI_SRST_RESET_TYPE_SHUTDOWN, SBI_SRST_RESET_REASON_NONE);
}

/* Cold reboot */
static inline void sbi_cold_reboot(void) {
    sbi_system_reset(SBI_SRST_RESET_TYPE_COLD_REBOOT, SBI_SRST_RESET_REASON_NONE);
}

/* Warm reboot */
static inline void sbi_warm_reboot(void) {
    sbi_system_reset(SBI_SRST_RESET_TYPE_WARM_REBOOT, SBI_SRST_RESET_REASON_NONE);
}

/* TIME: Set timer (next event after 'stime_value' ticks) */
static inline void sbi_set_timer(uint64_t stime_value) {
    sbi_ecall(SBI_EXT_TIME, SBI_EXT_TIME_SET_TIMER,
              stime_value, 0, 0, 0, 0, 0);
}

/* Legacy shutdown (fallback if SRST not available) */
static inline void sbi_legacy_shutdown(void) {
    sbi_ecall_legacy(SBI_EXT_LEGACY_SHUTDOWN, 0, 0, 0);
}

#endif /* SBI_H */
