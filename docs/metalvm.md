# MetalVM and MetalRV64 VM — Architecture

SageOS-RV runs Sage code through **MetalRV64**, a bare-metal, libc-free RISC-V register-based bytecode VM. A companion **stack-based MetalVM** provides shared value constructors (mv_num, mv_nil, etc.) and Q32.32 fixed-point math.

---

## What Is MetalRV64 VM?

MetalRV64 (`kernel/vm/metal_rv64_vm_impl.c`, ~1240 lines) is a freestanding RISC-V 64-bit register-based VM that executes SGRV bytecode (produced by `sagevm compile --riscv`). It implements:

- **RV64I instruction set**: LUI, AUIPC, JAL, JALR, BRANCH, IMM, REG, LOAD, STORE, LDC, VMSYS
- **Custom Sage opcodes** (via VMSYS funct3 groups):
  - `F3=0` (VM_OPS): HALT, PRINT, CALL, TRY/RAISE, NOP/bind, **CMP_BINARY** (EQ/NEQ/LT/GT/LE/GE)
  - `F3=1` (GPU_OPS): stubbed
  - `F3=2` (OBJ_OPS): GET/SET global, NEW_FUNC, ARRAY/DICT/TUPLE, INDEX/PROP
- **32 × 64-bit registers** (x0 hardwired to 0)
- **Call stack**: 256 entries (chunk_idx, return_pc, saved_ra)
- **Memory stack**: 1024 entries for LOAD/STORE
- **Builtins**: mem_write, mem_read, readline, streq, shell_exec, wdog_kick, array, push, len, str, int

### Q32.32 Fixed-Point

All numeric values use Q32.32 fixed-point format:
- `fp_from_int(i)` = `i << 32`
- `fp_mul(a, b)` = `(a * b) >> 32` (128-bit intermediate)
- `fp_div(a, b)` = shift-and-subtract long division (no `__divti3`)

### VMO_CMP_BINARY

Added in v0.3.0: generic binary comparison opcode (sub_op=0x0D). The `funct7` field encodes the comparison type:
- `CMP_EQ` (0), `CMP_NEQ` (1), `CMP_LT` (2), `CMP_GT` (3), `CMP_LE` (4), `CMP_GE` (5)

Supports MV_NUM (numeric), MV_STR (string via rv_strcmp), and MV_BOOL comparisons. This enables `if cmd == "help":` in Sage code compiled with `--riscv`.

The C backend defines the opcode and comparison types in `kernel/vm/metal_rv64_vm.h`
(`RV_VMO_CMP_BINARY`, `CMP_EQ`..`CMP_GE`) and dispatches them in `handle_vmsys()`.

---

## Execution Model

### Two-Phase Chunk Initialization

```c
// Phase 1: run definition chunks (SET globals)
for (int i = 1; i < vm.chunk_count; i++)
    metal_rv64_vm_run(&vm);

// Phase 2: run main body (uses registered globals)
if (vm.chunk_count > 0)
    metal_rv64_vm_run(&vm);
```

Register state persists between chunk executions.

### SGRV Binary Format

```
Offset  Size  Field
------  ----  -----
0       4     Magic: 'SGRV' (0x53 0x47 0x52 0x56)
4       2     Version (0x00 0x01)
6       2     Constant count (big-endian)
8       N     Constant pool entries:
              - Type 1 (MV_NUM): 8 bytes IEEE 754 → Q32.32
              - Type 3 (MV_STR): 2 bytes length + string
N+8     4     Chunk count (big-endian)
N+12    M     Chunks: 4 bytes length + code
```

---

## Host-Side Testing

```bash
./sagemake compile-shell   # shell/shell.sage → shell/shell.sgvm
./sagemake run-shell       # sagevm run shell/shell.sgvm --riscv

./sagemake compile-kernel  # kernel/core/kmain.sage → SGRV
./sagemake run-kernel      # sagevm run kernel/core/kmain.sgvm --riscv
```

### C-Only Mode (no SageVM)

```bash
SAGEVM_ENABLED=0 ./sagemake build
SAGEVM_ENABLED=0 ./sagemake qemu
```

Boots directly into a C echo loop — no Sage bytecode compilation required. Useful for hardware bring-up and validating the C kernel layer.

---

## All libc-free, all freestanding

Every C file compiled into the kernel uses `-nostdlib -ffreestanding -DSAGE_BARE_METAL`. Zero libc dependencies. All memory/string operations use custom `bm_*`/`rv_*` implementations.
