/* rtos/sagertos_glue.c — SageOS-RV kernel → SageRTOS bridge
 *
 * Compiled only when SAGE_RTOS is defined (sagemake sets this flag).
 * Links against sagertos_rv64.o + sagertos_rv64_asm.o.
 *
 * Responsibilities:
 *   1. Hide the timer_freq parameter behind a global so the kernel can
 *      call sagertos_glue_init(hw.timer_freq) in one line.
 *   2. Route kernel timer ticks into sagertos_rv64_tick_handler().
 *   3. Provide a single place to extend RTOS<->kernel integration
 *      (e.g. wiring PMM allocator into RTOS queue backing stores).
 */

#ifdef SAGE_RTOS

#include "sagertos_glue.h"

static int _rtos_ready = 0;

void sagertos_glue_init(uint64_t timer_freq_hz) {
    sagertos_rv64_init(timer_freq_hz);
    _rtos_ready = 1;
}

void sagertos_glue_tick(void) {
    if (_rtos_ready)
        sagertos_rv64_tick_handler();
}

int sagertos_glue_task_create(void (*fn)(void *), void *arg,
                              uint64_t stack_words, uint8_t priority) {
    if (!_rtos_ready) return -1;
    return sagertos_rv64_task_create(fn, arg, stack_words, priority);
}

void sagertos_glue_start(void) {
    if (_rtos_ready)
        sagertos_rv64_start();
}

int sagertos_glue_ready(void) {
    return _rtos_ready;
}

#endif /* SAGE_RTOS */
