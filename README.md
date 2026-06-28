# SageOS-RV

**A pure-Sage operating system for RISC-V 64.**  
Target hardware: LicheeRV Nano (Sophgo SG2002, rv64imac). Development platform: QEMU `virt`.

---

## Architecture Overview

SageOS-RV uses a two-layer execution model:

```
┌─────────────────────────────────────────────┐
│  SageOS-RV kernel image (sageos.elf)        │
│                                             │
│  boot.S          bare-metal entry (C/ASM)   │
│  fallback_kernel.c  C boot stage            │
│  dtb.c / vmm.c   hardware abstraction       │
│                                             │
│  .sgvm_shell section                        │
│  ┌─────────────────────────────────────┐   │
│  │  shell.sgvm  (MetalVM bytecode)     │   │
│  │  compiled from shell/shell.sage     │   │
│  │  via: sagevm compile --riscv        │   │
│  └─────────────────────────────────────┘   │
│                                             │
│  MetalVM  (metal_vm.c + metal_rv64_vm.c)    │
│  bare-metal, libc-free bytecode interpreter │
└─────────────────────────────────────────────┘
```

| Layer | Source | Compiled by | Role |
|---|---|---|---|
| Boot stub | `boot/arch/rv64/boot.S` | `riscv64-linux-gnu-gcc` | Minimal ASM entry, jumps to `sage_kernel_main` |
| C kernel | `kernel/fallback_kernel.c` | `riscv64-linux-gnu-gcc -nostdlib -ffreestanding` | Hardware init, PMM, VMM, timer, shell dispatch |
| MetalVM | `metal_vm.c` / `metal_rv64_vm.c` | same | Bare-metal bytecode interpreter (no libc) |
| Shell | `shell/shell.sage` | `sagevm compile --riscv` | Interactive shell as `.sgvm` bytecode |
| Kernel logic | `kernel/kmain.sage` | `sagevm compile --riscv` | Kernel init as `.sgvm` bytecode |

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

# SageLang (for .sage -> .sgvm compilation)
# https://github.com/Night-Traders-Dev/SageLang
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
========================================
  SageOS-RV v0.1.0-alpha
  Pure Sage Operating System
  RISC-V 64 | QEMU virt
========================================

[1/7] Console initialized
  DTB: 0x20000 KB @ 0x80200000, timer 10 MHz
[2/7] Memory: 32768 pages (131072 KB) — 512 bitmap words
[3/7] VMM: SV39 active
[4/7] Timer: stimecmp @ 10 MHz, 500ms
[5/7] Kernel ready
[6/7] MetalVM: shell.sgvm embedded (8258 bytes)
[7/7] Starting shell...

SageOS-RV Shell (type 'help' for commands)

sage#
```

---

## sagemake Commands

| Command | Description |
|---|---|
| `build` | Full build: boot + kernel + MetalVM + shell.sgvm |
| `clean` | Remove build artifacts |
| `qemu` | Launch QEMU with the built kernel |
| `build-run` | `build` then `qemu` |
| `compile-kernel` | `sagevm compile kernel/kmain.sage kernel/kmain.sgvm --riscv` |
| `run-kernel` | `sagevm run kernel/kmain.sgvm` (host-side test) |
| `compile-shell` | `sagevm compile shell/shell.sage shell/shell.sgvm --riscv` |
| `run-shell` | `sagevm run shell/shell.sgvm` (host-side test) |
| `setup-srvm` | Copy SRVM sources from SageVM repo into `kernel/` |
| `version` | Print toolchain versions |

See [docs/sagemake.md](docs/sagemake.md) for full documentation.

---

## MetalVM and SRVM

All Sage code in SageOS-RV runs through **MetalVM**, a bare-metal bytecode interpreter from [SageLang](https://github.com/Night-Traders-Dev/SageLang) built with `-nostdlib -ffreestanding`. No libc, no dynamic allocation outside the kernel's own PMM.

The **SRVM** (Sage RISC-V VM) is a pure-Sage VM layer (`kernel/srvm_vm.sage` + `kernel/srvm_core.sage`) that provides the in-kernel scripting environment. It is compiled to `.sgvm` bytecode and embedded in the kernel image.

See [docs/metalvm.md](docs/metalvm.md) for the full architecture.

---

## Repository Layout

```
SageOS-RV/
├── boot/
│   └── arch/rv64/
│       ├── boot.S          bare-metal entry point
│       └── linker.ld       memory layout + .sgvm_shell section
├── kernel/
│   ├── fallback_kernel.c   C boot kernel + shell dispatch
│   ├── kmain.sage          Sage kernel logic
│   ├── kmain.sgvm          compiled MetalVM bytecode (committed)
│   ├── dtb.c / dtb.h       device tree parser
│   ├── vmm.c / vmm.h       SV39 virtual memory
│   ├── sbi.h               SBI call wrappers
│   ├── srvm_core.sage      SRVM core (from SageVM)
│   └── srvm_vm.sage        SRVM VM (from SageVM)
├── shell/
│   ├── shell.sage          interactive shell source
│   └── shell.sgvm          compiled MetalVM bytecode
├── drivers/                Sage driver sources
├── config/
│   └── build.conf          board / toolchain config
├── docs/
│   ├── metalvm.md          MetalVM + SRVM architecture
│   └── sagemake.md         sagemake command reference
├── sagemake                build system
└── VERSION
```

---

## License

See [LICENSE](LICENSE).
