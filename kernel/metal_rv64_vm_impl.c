/*
 * kernel/metal_rv64_vm_impl.c
 *
 * Thin translation unit that instantiates the MetalVM RV64 back-end.
 * metal_rv64_vm.h is a header-only library -- defining
 * METAL_RV64_VM_IMPLEMENTATION before including it emits all the
 * RV64-specific dispatch bodies into this single TU.
 *
 * This file is generated/updated by:  ./sagemake setup-metalvm
 *
 * Compile flags (enforced by sagemake):
 *   -march=rv64imac_zicsr_zifencei -mabi=lp64
 *   -nostdlib -ffreestanding -O2
 *   -DSAGE_BARE_METAL -DSAGE_METAL_VM
 *   -I<kernel/>
 */
#define METAL_RV64_VM_IMPLEMENTATION
#include "metal_rv64_vm.h"
