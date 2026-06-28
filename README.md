# SageOS-RV

**A Pure Sage operating system for the LicheeRV Nano (RISC-V 64).**

SageOS-RV is a dogfooding operating system built almost entirely in SageLang,
targeting the Sophgo SG2002 SoC on the Sipeed LicheeRV Nano. Every line above
the hardware abstraction layer is written in Sage itself, making this the
canonical demonstration that SageLang can build a complete software stack from
bare metal to applications.

## Architecture

```
LicheeRV Nano (SG2002, RISC-V 64)
      |
  ROM Boot -> Vendor FSBL -> OpenSBI -> SageBoot
      |
  Sage Kernel (PMM, VMM, SBI, Timer, Shell)
      |
  +-----------+-----------+
  |           |           |
 SageRTOS   SageVM    Sage VFS
 Scheduler  Runtime    VFS/FS
  |           |           |
  +-----------+-----------+
      |
  Sage System Libraries
      |
  Sage Shell -> User Applications
```

## Boot Sequence

```
QEMU virt machine
  |
  ROM (reset vector at 0x80000000)
  |
  OpenSBI v1.8 (M-mode, 0x80000000)
    - Platform init, PMP config
    - Domain0: S-mode at 0x80200000
    - Delegates IRQs (MIDELEG) and traps (MEDELEG)
    - SBI v3.0 extensions: srst, time, dbcn
  |
  +--> boot.S (S-mode at 0x80200000)
         |  1. SBI ecall putchar: "SBI"
         |  2. Init UART (IER/FCR/LCR via byte accesses)
         |  3. Direct UART putchar: "K!"
         |  4. Clear BSS
         |  5. Call sage_kernel_main()
         |
         +--> fallback_kernel.c (C kernel)
                |  Phase 1: Console (UART 16550A @ 0x10000000)
                |  Phase 2: PMM (128 MB RAM, 32768 pages)
                |  Phase 3: Timer (SBI time, 500ms interval)
                |  Phase 4: Shell (sage# prompt)
                |
                Commands: help version mem uptime reboot poweroff halt clear echo
```

## Current Status — v0.1.0-alpha

| Component          | Status     | Details                                    |
|--------------------|------------|--------------------------------------------|
| Boot assembly      | ✅ Done    | SBI ecall + UART init, byte accesses       |
| UART driver        | ✅ Done    | 16550A direct MMIO (polling)               |
| SBI wrappers       | ✅ Done    | putchar, getchar, set_timer, srst          |
| PMM                | ✅ Done    | Flat 128MB, 4K pages, 32768 total          |
| Timer (polling)    | ✅ Done    | SBI TIME extension, 500ms periodic tick    |
| Shell              | ✅ Done    | Line editing, 6 commands + echo            |
| System reset       | ✅ Done    | SBI SRST: reboot, poweroff, halt           |
| Timer IRQ (stvec)  | ❌ Blocked | sstatus.SIE is WARL-0 in QEMU 10.2 virt    |
| Sage transpilation | ❌ Pending | sage --emit-c fails, using C fallback      |
| VMM                | ❌ Pending | Page tables, virtual memory                |
| DTB parser         | ❌ Pending | FDT/flattened device tree                  |
| Disk/FS            | ❌ Pending | VirtIO block, FAT32                        |

## Build System

```bash
# Full build
./sagemake build

# Run in QEMU
./sagemake qemu

# Build + Run
./sagemake build-run

# Clean artifacts
./sagemake clean
```

### Build Pipeline

1. SageLang `--emit-c` (failed → fallback to C)
2. `boot.S` compiled with `riscv64-linux-gnu-gcc` (`rv64imac_zicsr_zifencei`, `lp64`)
3. C kernel compiled (`-nostdlib -ffreestanding -O2`)
4. Linked at `0x80200000` with custom linker script
5. `objcopy` → `sageos.elf` / `sageos.bin`

### QEMU Command

```bash
qemu-system-riscv64 \
  -machine virt \
  -cpu rv64 \
  -smp 1 \
  -m 128M \
  -nographic \
  -bios /usr/lib/riscv64-linux-gnu/opensbi/generic/fw_dynamic.bin \
  -kernel build/sageos.elf \
  -serial mon:stdio
```

## Requirements

- **SageLang** v3.9.5+ (`sage` on PATH)
- **QEMU** 8+ (`qemu-system-riscv64`)
- **RISC-V cross-compiler** `riscv64-linux-gnu-gcc` (GCC 13+)
- **OpenSBI** v1.3+ (`fw_dynamic.bin`)

## Project Structure

```
SageOS-RV/
  sagemake          Build system (bash)
  boot/             SageBoot (entry, SBI, loader)
    arch/rv64/       boot.S, linker.ld, sbi.h
  kernel/           Kernel modules
    kmain.sage      Bootstrap (SageLang → transpiled)
    fallback_kernel.c  Working C kernel (fallback)
    sbi.h           SBI ecall wrappers
  drivers/          Device drivers
  rtos/             SageRTOS (scheduler, IPC)
  fs/               Filesystem
  shell/            Sage Shell
  lib/              System libraries
  tools/            Development tools
  tests/            Test suite
  config/           Build configurations
  images/           Built images
```

## Roadmap

- **Phase 0** ✅ Infrastructure (repo, build, QEMU, OpenSBI)
- **Phase 1** ✅ SageMake (build system)
- **Phase 2** ✅ SageBoot (RISC-V boot, SBI, UART, PMM)
- **Phase 3** 🔶 Kernel (VMM, interrupts, DTB, scheduler iface)
- **Phase 4** ❐ SageRTOS (scheduling, sync, IPC)
- **Phase 5** ❐ SageVM (runtime, GC, bytecode)
- **Phase 6** ❐ Filesystem (VFS, FAT32, InitFS)
- **Phase 7** ❐ Drivers (SPI, I2C, GPIO, SD, USB)
- **Phase 8** ❐ Shell (pipes, redirection, scripting)
- **Phase 9** ❐ Userspace (ls, cp, cat, ps, sh)
- **Phase 10** ❐ Networking (TCP/IP stack)
- **Phase 11** ❐ Security (users, permissions, capabilities)
- **Phase 12** ❐ Dev Tools (compiler, linker, debugger)
- **Phase 13** ❐ Self Hosting

## Known Issues

- `sstatus.SIE` cannot be set in QEMU 10.2 virt machine (`WARL` tied to 0).
  Timer works via SIP.STIP polling + SBI time extension until root cause is
  determined. Does not affect LicheeRV Nano hardware target.
- SageLang v3.9.5 `--emit-c` produces bare-metal-unfriendly code. The C
  fallback kernel (`fallback_kernel.c`) is the active artifact.

## License

MIT
