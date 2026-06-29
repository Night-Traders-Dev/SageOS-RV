/*
 * kernel/metal_vm_impl.c
 *
 * MetalVM implementation translation unit for SageOS-RV.
 *
 * metal_vm.h declares the public API; the actual function bodies live
 * in the SageLang VM sources:
 *
 *   core/src/vm/vm.c          -- metal_vm_init, metal_vm_run, metal_vm_step, etc.
 *   core/src/vm/program.c     -- metal_vm_load_binary, metal_vm_load
 *   core/src/vm/bytecode.c    -- bytecode helpers
 *   core/src/vm/runtime.c     -- runtime helpers
 *
 * These are compiled as SEPARATE objects by sagemake (see build step 5).
 * This file only needs to include the public header so that any TU that
 * #includes "metal_vm_impl.c" still gets the type definitions.
 *
 * Bare-metal guards:
 *   -DSAGE_BARE_METAL  -- disables all OS / libc code paths in the VM
 *   -DSAGE_METAL_VM    -- enables the freestanding MetalVM code paths
 *   -ffreestanding -nostdlib
 */

#include "metal_vm.h"
#include "metal_rv64_vm.h"

/*
 * Nothing to instantiate here -- all symbols are provided by the objects
 * compiled from kernel/metalvm/vm.c et al. (added to the link line by
 * sagemake).  This file is kept as a compilation smoke-test: if the
 * include paths or the API header are broken, this TU will fail first.
 */
