# SageOS-RV

**A pure-Sage operating system for RISC-V 64.**  
Target hardware: LicheeRV Nano (Sophgo SG2002, rv64imac). Development platform: QEMU `virt`.

---

## Architecture Overview

SageOS-RV uses a layered VM architecture:

```
┌──────────────────────────────────────────────────┐
│  SageOS-RV kernel image (sageos.elf)             │
│                                                  │
│  Layer 3: SRVM (SageVM) — Sage-level VM          │
│  kernel/srvm_core.sage + srvm_vm.sage            │
│  Compiled into SGRV bytecode via --riscv         │
│  Provides module system, imports, RISC-V ops     │
│                                                  │
│  Layer 2: MetalRV64VM (C) — Bare-metal adapter   │
│  kernel/metal_rv64_vm_impl.c                     │
│  Q32.32 fixed-point, no libc, no FPU             │
│  Executes SGRV bytecode on bare metal            │
│                                                  │
│  Layer 1: C kernel — Hardware abstraction        │
│  fallback_kernel.c, boot.S, dtb.c, vmm.c         │
│  UART, PMM, VMM, SBI wrappers                   │
│                                                  │
│  Embedded sections:                              │
│  .sgvm_kernel — kmain.sgvm (SGRV bytecode)       │
│  .sgvm_shell  — shell.sgvm  (SGRV bytecode)      │
└──────────────────────────────────────────────────┘
```

| Layer | Source | Role |
|---|---|---|
| **SRVM** | `kernel/srvm_*.sage` (from [SageVM](https://github.com/Night-Traders-Dev/SageVM)) | Sage-level VM: compilation target, import resolver, RISC-V opcodes |
| **MetalRV64VM** | `kernel/metal_rv64_vm_impl.c` (adapted from sagelang) | Bare-metal C adapter: Q32.32 fixed-point, no FPU |
| **C kernel** | `kernel/fallback_kernel.c`, `boot.S` | Hardware init, UART, PMM, VMM |
| **Shell** | `shell/shell.sage` | Interactive shell, compiled to SGRV |
| **Kernel logic** | `kernel/kmain.sage` | Sage kernel init, compiled to SGRV |

### Compilation Flow

```
shell/shell.sage ──────────────────────────┐
kernel/kmain.sage + srvm_*.sage ─────────┤
                                           │
    sagevm compile --riscv  (SageVM SRVM)  │
                                           ▼
    .sgrv bytecode (32-bit RV64I instructions)
                                           │
    riscv64-linux-gnu-objcopy              │
                                           ▼
    section .sgvm_kernel / .sgvm_shell     │
                                           │
    riscv64-linux-gnu-ld                   │
                                           ▼
    sageos.elf  ─►  QEMU -cpu rv64        │
                                           │
    MetalRV64VM (Q32.32 fixed-point)      │
    executes SGRV bytecode on bare metal   │
```

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
[MetalRV64] Running shell...

========================================
  SageOS-RV v0.2.0
  Pure Sage Operating System
  RISC-V 64 | QEMU virt
========================================

[OK] Console initialized
[OK] MetalRV64: shell loaded

Type 'help' for commands.

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
| `compile-kernel` | `sagevm compile kernel/kmain.sage kernel/kmain.sgvm` |
| `run-kernel` | `sagevm run kernel/kmain.sgvm` (host-side test) |
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

- **Kernel in C fallback**: `kmain.sage` uses SRVM with module imports that need runtime global resolution. The kernel boot path currently skips Sage kernel init and goes directly to the shell via MetalRV64 VM.
- **Shell**: Runs as SGRV bytecode through the MetalRV64 RISC-V register VM. Limited to Sage builtins (print, etc.). Full interactive shell with command processing requires SRVM runtime integration.
- **sstatus.SIE WARL-0**: On QEMU's `-cpu rv64` virt machine, supervisor interrupts are emulation-restricted. Poll `SIP.STIP` as a workaround.

---

## License

See [LICENSE](LICENSE).
