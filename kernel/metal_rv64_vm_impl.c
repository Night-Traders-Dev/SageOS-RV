// ============================================================================
// metal_rv64_vm_impl.c — RV64-specific MetalVM extension stubs
// ============================================================================
// Includes metal_rv64_vm.h and provides bare-metal RISC-V register I/O
// helpers that the RV64 backend may call. No libc, no malloc.
// ============================================================================

#ifdef SAGELANG_METAL_RV64_VM_H_PATH
#  include SAGELANG_METAL_RV64_VM_H_PATH
#else
#  include "metal_rv64_vm.h"
#endif

// RISC-V MMIO read/write helpers (volatile word access)
static inline void rv64_mmio_write32(unsigned long addr, unsigned int val) {
    *((volatile unsigned int *)addr) = val;
}

static inline unsigned int rv64_mmio_read32(unsigned long addr) {
    return *((volatile unsigned int *)addr);
}

// CSR access (machine-mode)
static inline unsigned long rv64_rdtime(void) {
    unsigned long t;
    __asm__ volatile ("rdtime %0" : "=r"(t));
    return t;
}

static inline unsigned long rv64_rdcycle(void) {
    unsigned long c;
    __asm__ volatile ("rdcycle %0" : "=r"(c));
    return c;
}

// WFI — wait for interrupt (power-saving idle)
static inline void rv64_wfi(void) {
    __asm__ volatile ("wfi");
}
