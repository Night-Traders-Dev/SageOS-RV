/*
 * kernel/metal_vm_impl.c
 *
 * Thin translation unit that instantiates the MetalVM implementation.
 * metal_vm.h is a header-only library -- defining METAL_VM_IMPLEMENTATION
 * before including it emits all the function bodies into this single TU.
 *
 * This file is generated/updated by:  ./sagemake setup-metalvm
 *
 * Compile flags (enforced by sagemake):
 *   -march=rv64imac_zicsr_zifencei -mabi=lp64
 *   -nostdlib -ffreestanding -O2
 *   -DSAGE_BARE_METAL -DSAGE_METAL_VM
 *   -I<kernel/>
 */
#define METAL_VM_IMPLEMENTATION
#include "metal_vm.h"
