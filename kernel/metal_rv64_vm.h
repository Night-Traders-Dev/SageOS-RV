/* kernel/metal_rv64_vm.h — in-tree shim for SageLang's RISC-V 64 MetalVM
 *
 * Same logic as metal_vm.h — uses the upstream header when SAGELANG_CORE
 * is set, otherwise falls back to the bundled copy.
 */

#ifndef SAGEOS_METAL_RV64_VM_SHIM_H
#define SAGEOS_METAL_RV64_VM_SHIM_H

#ifdef METAL_RV64_VM_HEADER_PATH
#  include METAL_RV64_VM_HEADER_PATH
#else
#  include "metal_rv64_vm_bundled.h"
#endif

#endif /* SAGEOS_METAL_RV64_VM_SHIM_H */
