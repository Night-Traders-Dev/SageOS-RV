# MetalVM and MetalRV64 VM — Architecture

SageOS-RV runs all Sage code through **MetalRV64**, a bare-metal, libc-free RISC-V register-based bytecode VM adapted from [SageVM](https://github.com/Night-Traders-Dev/SageVM). A companion **stack-based MetalVM** provides shared value constructors (mv_num, mv_nil, etc.) and fixed-point math.

---

## What Is MetalRV64 VM?

MetalRV64 (`kernel/metal_rv64_vm_impl.c`, ~1070 lines) is a freestanding RISC-V 64-bit register-based VM that executes SGRV bytecode (produced by `sagevm compile --riscv`). It implements:

- **RV64I instruction set**: LUI, AUIPC, JAL, JALR, BRANCH, IMM, REG, LOAD, STORE, LDC, VMSYS
- **Custom Sage opcodes** (via VMSYS): CALL, PRINT, HALT, GET/SET global, NEW_FUNC, ARRAY/DICT/TUPLE ops, builtins (str, int), TRY/RAISE
- **32 × 64-bit registers** (x0 hardwired to 0, x1 = ra, x10-x17 = a0-a7)
- **Call stack**: 256 entries preserving chunk_idx, return_pc, saved_ra
- **Memory stack**: 1024 entries for LOAD/STORE
- **String pool**: bump-allocated, null-terminated
- **Array/Dict pools**: fixed-size static arrays (no malloc)

### Key Properties

- **No libc** — all memory/string operations use local implementations
- **No FPU** — numbers stored as Q32.32 fixed-point (`int64_t`), not IEEE 754 double
- **No soft-float** — no `__adddf3`, `__fixdfdi`, `__divti3` dependencies
- **Static allocation** — VM instance is a single `static MetalRV64VM` struct
- **Bare-metal I/O** — `write_char`/`read_char` callbacks wired to UART driver
- **Sequential chunk init** — all chunks executed in order to register function bindings

---

## Q32.32 Fixed-Point Numbers

All numeric values use Q32.32 fixed-point format:

```
1 Q32.32 unit = 2^-32  (~2.33e-10)
Range: -2147483647.999... to +2147483647.999...
```

Operations:
- `fp_from_int(i)` = `i << 32` (integer → Q32.32)
- `fp_to_int(f)` = `f >> 32` (Q32.32 → integer, truncate)
- `fp_mul(a, b)` = `(a * b) >> 32` (128-bit intermediate)
- `fp_div(a, b)` = shift-and-subtract long division (no __int128 divide)

IEEE 754 constants from SGRV bytecode are converted via `fp_from_ieee754()`.

---

## Compilation Pipeline

```
shell/shell.sage (or kernel/kmain.sage)
      │
      ▼  sagevm compile --riscv
      │
shell/shell.sgvm   (SGRV RISC-V bytecode)
      │
      ▼  riscv64-linux-gnu-objcopy
         -I binary -O elf64-littleriscv
         --rename-section .data=.sgvm_shell
      │
build/shell_sgvm.o
      │
      ▼  riscv64-linux-gnu-ld -T linker.ld -nostdlib
      │
sageos.elf  (.sgvm_shell section @ linker symbols)
```

The linker script (`boot/arch/rv64/linker.ld`) defines both sections:

```ld
.sgvm_kernel : {
    _kernel_sgvm_start = .;
    KEEP(*(.sgvm_kernel))
    _kernel_sgvm_end = .;
} > RAM

.sgvm_shell : {
    _shell_sgvm_start = .;
    KEEP(*(.sgvm_shell))
    _shell_sgvm_end = .;
} > RAM
```

---

## Execution Model

### Sequential Chunk Initialization

The MetalRV64 VM follows the upstream SageVM convention: all SGRV chunks are
executed sequentially to register function bindings and global definitions
before the main kernel code runs:

```c
for (int i = 0; i < sage_vm.chunk_count; i++) {
    sage_vm.current_chunk_idx = i;
    sage_vm.bytecode = sage_vm.chunks[i];
    sage_vm.bytecode_length = sage_vm.chunk_lengths[i];
    sage_vm.pc = 0;
    int rc = metal_rv64_vm_run(&sage_vm);
    // ...
}
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

### Instruction Encoding

32-bit little-endian RV64I with custom opcodes:

| Opcode | Mnemonic | Description |
|--------|----------|-------------|
| 0x13   | ADDI     | Add immediate |
| 0x33   | REG      | Register-register ALU |
| 0x37   | LUI      | Load upper immediate |
| 0x17   | AUIPC    | Add upper immediate to PC |
| 0x5B   | LDC      | Load constant pool entry |
| 0x63   | BRANCH   | Conditional branch |
| 0x67   | JALR     | Jump and link register (incl. ret) |
| 0x6F   | JAL      | Jump and link |
| 0x03   | LOAD     | Load from memory stack |
| 0x23   | STORE    | Store to memory stack |
| 0x73   | VMSYS    | VM system ops (PRINT, CALL, etc.) |

VMSYS funct3 groups:
- `f3=0` (VM_OPS): HALT, PRINT, CALL, TRY/RAISE, NOP/bind
- `f3=1` (GPU_OPS): Stubbed
- `f3=2` (OBJ_OPS): GET/SET global, NEW_FUNC, ARRAY/DICT/TUPLE, GET/SET index/prop

---

## Stack-Based MetalVM (Companion)

`kernel/metal_vm_impl.c` provides:
- **Value constructors**: `mv_nil()`, `mv_num(i)`, `mv_num_fp(fp)`, `mv_bool(b)`, `mv_ptr(p)`, `mv_str()`
- **Fixed-point math**: `fp_mul`, `fp_div`, `fp_mod`, `fp_from_int`, `fp_to_int`
- **IEEE 754 conversion**: `fp_from_ieee754(bits)`
- **SGVM binary loader** (stack-based format, fallback for non-SGRV blobs)

Both VM implementations share `metal_vm.h` types (`MetalValue`, `MetalArray`, `MetalDict`, `MetalFunction`).

---

## Host-Side Testing

Before a full QEMU boot you can test `.sgvm` binaries on the host:

```bash
./sagemake compile-kernel   # kernel/kmain.sage -> kernel/kmain.sgvm
./sagemake run-kernel       # sagevm run kernel/kmain.sgvm --riscv

./sagemake compile-shell    # shell/shell.sage  -> shell/shell.sgvm
./sagemake run-shell        # sagevm run shell/shell.sgvm --riscv
```

This lets you iterate on Sage code without a cross-compile + QEMU cycle for every change.
