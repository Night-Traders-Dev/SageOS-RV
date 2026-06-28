/* rtos/sagertos_glue.h — SageOS-RV ↔ SageRTOS integration
 *
 * This header is the only SageRTOS surface the kernel needs to include.
 * It re-exports a small, stable API so fallback_kernel.c does not need
 * to know about the RTOS internals.
 *
 * Include path assumption:
 *   -I${SCRIPT_DIR}/rtos/SageRTOS/src/rv64
 *   -I${SCRIPT_DIR}/rtos
 */

#ifndef SAGERTOS_GLUE_H
#define SAGERTOS_GLUE_H

#include <stdint.h>

#ifdef SAGE_RTOS
#  include "sagertos_rv64.h"

/* Kernel-facing API -------------------------------------------------------- */

/* Call once after PMM + timer are up.
 * timer_freq_hz: value from DTB (hw.timer_freq) or 10_000_000 fallback. */
void sagertos_glue_init(uint64_t timer_freq_hz);

/* Call from the kernel's timer poll loop every tick.
 * Drives task wakeup + preemptive scheduling. */
void sagertos_glue_tick(void);

/* Convenience wrapper: create a kernel task.  Returns task ID or -1. */
int  sagertos_glue_task_create(void (*fn)(void *), void *arg,
                               uint64_t stack_words, uint8_t priority);

/* Start the scheduler.  Only call this if you want to hand the CPU to
 * the RTOS permanently.  For the current boot model we init + tick only
 * and the C shell remains in control. */
void sagertos_glue_start(void);

/* True after sagertos_glue_init() has been called. */
int  sagertos_glue_ready(void);

#else /* !SAGE_RTOS */

/* Stub implementations — compile cleanly without the RTOS sources */
static inline void sagertos_glue_init(uint64_t f)  { (void)f; }
static inline void sagertos_glue_tick(void)        {}
static inline int  sagertos_glue_task_create(
    void (*fn)(void *), void *arg, uint64_t sw, uint8_t p)
    { (void)fn; (void)arg; (void)sw; (void)p; return -1; }
static inline void sagertos_glue_start(void)       {}
static inline int  sagertos_glue_ready(void)       { return 0; }

#endif /* SAGE_RTOS */
#endif /* SAGERTOS_GLUE_H */
