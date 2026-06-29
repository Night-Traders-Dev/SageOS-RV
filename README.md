# SageOS-RV

**A pure-Sage operating system for RISC-V 64.**  
Target hardware: LicheeRV Nano (Sophgo SG2002, rv64imac). Development platform: QEMU `virt`.

---

## Architecture Overview

SageOS-RV uses the **MetalRV64** RISC-V register-based VM as the primary execution engine. All Sage code is compiled to SGRV bytecode (`sagevm compile --riscv`) and executed by the freestanding RV64 VM.

```
┌─────────────────────────────────────────────────┐
│  SageOS-RV kernel image (sageos.elf)            │
│                                                 │
│  boot.S              bare-metal entry (ASM)     │
│  fallback_kernel.c   C boot stage               │
│  dtb.c / vmm.c       hardware abstraction       │
│                                                 │
│  MetalRV64 VM  (metal_rv64_vm_impl.c)            │
│  freestanding RISC-V bytecode interpreter       │
│  Q32.32 fixed-point, no libc, no FPU            │
│                                                 │
│  .sgvm_kernel section                           │
│  ┌─────────────────────────────────────────┐   │
│  │  kmain.sgvm  (SGRV bytecode)            │   │
│  │  compiled via: sagevm compile --riscv   │   │
│  └─────────────────────────────────────────┘   │
│                                                 │
│  .sgvm_shell section                            │
│  ┌─────────────────────────────────────────┐   │
│  │  shell.sgvm   (SGRV bytecode)            │   │
│  │  compiled via: sagevm compile --riscv   │   │
│  └─────────────────────────────────────────┘   │
└─────────────────────────────────────────────────┘
```

| Layer | Source | Compiled by | Role |
|---|---|---|---|
| Boot stub | `boot/arch/rv64/boot.S` | `riscv64-linux-gnu-gcc` | Minimal ASM entry, jumps to `sage_kernel_main` |
| C kernel | `kernel/fallback_kernel.c` | `riscv64-linux-gnu-gcc -nostdlib -ffreestanding` | Hardware init, PMM, VMM, MetalRV64 VM bootstrap |
| MetalRV64 VM | `kernel/metal_rv64_vm_impl.c` | same | Freestanding RISC-V register VM (Q32.32 fixed-point) |
| Stack VM | `kernel/metal_vm_impl.c` | same | Stack-based MetalVM (provides value constructors) |
| Kernel logic | `kernel/kmain.sage` | `sagevm compile --riscv` | Kernel init as SGRV bytecode |
| Shell | `shell/shell.sage` | `sagevm compile --riscv` | Interactive shell as SGRV bytecode |

---

## Quick Start

### Prerequisites

```bash
# RISC-V cross-toolchain
sudo apt install gcc-riscv64-linux-gnu binutils-riscv64-linux-gnu

# QEMU
sudo apt install qemu-system-misc

# OpenSBI (for QEMU -bios)
sudo apt install opensbi

# SageVM (for .sage -> .sgrv compilation)
# https://github.com/Night-Traders-Dev/SageVM
```

### Build and Run

```bash
git clone https://github.com/Night-Traders-Dev/SageOS-RV
cd SageOS-RV

./sagemake build        # compile everything
./sagemake qemu         # boot in QEMU
./sagemake build-run    # build + boot in one step
```

### Expected Boot Output

```
SBIK!
[MetalRV64] Initializing...
[MetalRV64] Loading kmain.sgvm...
[MetalRV64] Running kernel...

========================================
  SageOS-RV v0.1.0-alpha
  Pure Sage Operating System
  RISC-V 64 | QEMU virt
========================================

[1/7] Console initialized
[2/7] Memory: ...
[3/7] Interrupts...
[4/7] Timer...
[5/7] DTB...
[6/7] SRVM init...
[7/7] Launching shell.sgvm via MetalVM...

sage#
```

---

## sagemake Commands

| Command | Description |
|---|---|
| `build` | Full build: boot + kernel + MetalRV64 VM + SGRV blobs |
| `clean` | Remove build artifacts |
| `qemu` | Launch QEMU with the built kernel |
| `build-run` | `build` then `qemu` |
| `compile-kernel` | `sagevm compile kernel/kmain.sage kernel/kmain.sgvm --riscv` |
| `run-kernel` | `sagevm run kernel/kmain.sgvm --riscv` (host-side test) |
| `compile-shell` | `sagevm compile shell/shell.sage shell/shell.sgvm --riscv` |
| `run-shell` | `sagevm run shell/shell.sgvm --riscv` (host-side test) |
| `setup-srvm` | Copy SRVM sources from SageVM repo into `kernel/` |
| `setup-metalvm` | Validate MetalVM headers in `kernel/` |
| `setup-rtos` | Clone SageRTOS submodule |
| `version` | Print toolchain versions |

See [docs/sagemake.md](docs/sagemake.md) for full documentation.

---

## MetalRV64 VM

All Sage code in SageOS-RV runs through **MetalRV64**, a bare-metal RISC-V register-based bytecode interpreter adapted from [SageVM](https://github.com/Night-Traders-Dev/SageVM). It executes SGRV format binaries (compiled with `sagevm compile --riscv`).

Key properties:
- **Freestanding** — no libc, no malloc, no FPU. `-nostdlib -ffreestanding`
- **Q32.32 fixed-point** — numbers stored as `int64_t`, no IEEE 754 double dependency
- **RV64I instruction set** — LUI, AUIPC, JAL, JALR, BRANCH, ALU, LOAD/STORE, LDC, VMSYS
- **Static pools** — arrays, dicts, strings, constants all pre-allocated
- **Sequential chunk init** — all 62 chunks executed to register function bindings

A companion **stack-based MetalVM** (`metal_vm_impl.c`) provides value constructors and fixed-point math helpers shared by both VMs.

See [docs/metalvm.md](docs/metalvm.md) for the full architecture.

---

## Repository Layout

```
SageOS-RV/
├── boot/
│   └── arch/rv64/
│       ├── boot.S              bare-metal entry point
│       └── linker.ld           memory layout + SGRV sections
├── kernel/
│   ├── fallback_kernel.c       C boot kernel + MetalRV64 dispatch
│   ├── kmain.sage              Sage kernel logic
│   ├── kmain.sgvm              compiled SGRV bytecode
│   ├── metal_rv64_vm.h         RV64 VM public API
│   ├── metal_rv64_vm_impl.c    RV64 VM freestanding implementation
│   ├── metal_vm.h              MetalVM types + value constructors
│   ├── metal_vm_impl.c         Stack VM + fixed-point math
│   ├── dtb.c / dtb.h           device tree parser
│   ├── vmm.c / vmm.h           SV39 virtual memory
│   ├── sbi.h                   SBI call wrappers
│   ├── srvm_core.sage          SRVM core (from SageVM)
│   └── srvm_vm.sage            SRVM VM (from SageVM)
├── shell/
│   ├── shell.sage              interactive shell source
│   └── shell.sgvm              compiled SGRV bytecode
├── drivers/                    Sage driver sources
├── rtos/                       SageRTOS submodule (optional)
├── config/
│   └── build.conf              board / toolchain config
├── docs/
│   ├── metalvm.md              MetalVM + MetalRV64 architecture
│   ├── sagemake.md             sagemake command reference
│   ├── kernel.md               kernel architecture
│   └── sagertos.md             SageRTOS integration
├── sagemake                    build system
└── VERSION
```

---

## SRVM — Sage RISC-V VM

SRVM (`kernel/srvm_vm.sage` + `kernel/srvm_core.sage`) is a pure-Sage scripting VM that provides the in-kernel scripting environment. SRVM sources are copied from [SageVM](https://github.com/Night-Traders-Dev/SageVM):

```bash
./sagemake setup-srvm
```

---

## Known Limitations

- **Global initialization**: The kernel Sagelang code uses `OBJ_GET_GLOBAL` which requires pre-populated globals (`mem_write`, `UART_BASE`, etc.). The MetalRV64 VM currently lacks built-in global registration — the kernel executes chunk 0 which attempts to resolve unpopulated globals.
- **sstatus.SIE WARL-0**: On QEMU's `-cpu rv64` virt machine, writing to `sstatus.SIE` is silently ignored. Poll `SIP.STIP` as a workaround.

---

## License

See [LICENSE](LICENSE).
