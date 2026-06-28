# MetalVM and SRVM — Architecture

SageOS-RV runs all Sage code through **MetalVM**, a bare-metal, libc-free bytecode interpreter that is part of the [SageLang](https://github.com/Night-Traders-Dev/SageLang) core.

---

## What Is MetalVM?

MetalVM (`core/src/metal_vm.c` + `core/src/metal_rv64_vm.c` in the SageLang repo) is a compact bytecode VM designed specifically for environments with no operating system and no C standard library. It compiles under:

```
-std=c11 -ffreestanding -nostdlib -O2
```

The RV64 back-end (`metal_rv64_vm.c`) uses RISC-V 64-bit register conventions and produces bytecode that the `--riscv` flag of `sagevm compile` targets.

### Key Properties

- **No libc** — no `malloc`, `printf`, `memcpy` from the system. All memory comes from the kernel PMM via static allocation.
- **No dynamic linking** — the VM and its bytecode blob are baked into the ELF image at link time.
- **Bare-metal I/O** — the VM calls `write_char` / `read_char` callbacks wired to the kernel's UART driver (`uart_putc` / `uart_getchar`).
- **Static VM instance** — `metal_vm_glue.c` holds a single `static MetalVM sage_vm` — no heap required.

---

## Compilation Pipeline

```
shell/shell.sage
      │
      ▼  sagevm compile shell/shell.sage shell/shell.sgvm --riscv
      │
shell/shell.sgvm   (RV64 MetalVM bytecode, ~8 KB)
      │
      ▼  riscv64-linux-gnu-objcopy
         -I binary -O elf64-littleriscv
         --rename-section .data=.sgvm_shell
      │
build/shell_sgvm.o
      │
      ▼  riscv64-linux-gnu-ld -T linker.ld
      │
sageos.elf  (.sgvm_shell section @ _shell_sgvm_start .. _shell_sgvm_end)
```

The linker script (`boot/arch/rv64/linker.ld`) defines the section:

```ld
.sgvm_shell : {
    _shell_sgvm_start = .;
    KEEP(*(.sgvm_shell))
    _shell_sgvm_end = .;
} > RAM
```

At runtime `fallback_kernel.c` reads `_shell_sgvm_start` and `_shell_sgvm_end` to locate the blob and passes it directly to `sage_metal_vm_exec()`.

---

## metal_vm_glue.c

`kernel/metal_vm_glue.c` is the integration shim between the C kernel and MetalVM:

```c
// Wires UART I/O into the VM
void sage_metal_vm_init(void);

// Returns the static VM instance pointer
MetalVM *sage_metal_vm_get(void);

// Load bytecode and run — returns VM exit code
int sage_metal_vm_exec(const uint8_t *bytecode, uint32_t len);
```

The `SAGE_METAL_VM` preprocessor flag must be set at compile time (done automatically by `sagemake build` via `-DSAGE_METAL_VM`) for the real symbols to be linked; otherwise no-op stubs are compiled in.

---

## SRVM — Sage RISC-V VM

SRVM (`kernel/srvm_vm.sage` + `kernel/srvm_core.sage`) is a pure-Sage scripting VM that runs *inside* MetalVM. It provides the in-kernel scripting layer:

```
[ Sage script ]  →  SRVM interpreter (pure Sage)  →  MetalVM bytecode  →  hardware
```

SRVM sources are sourced from [SageVM](https://github.com/Night-Traders-Dev/SageVM) and staged into `kernel/` either manually or via:

```bash
./sagemake setup-srvm
```

---

## Shell Dispatch Logic

At boot, `sage_kernel_main` in `fallback_kernel.c` follows this decision tree:

```
_shell_sgvm_end - _shell_sgvm_start > 8 bytes?
│
├─ YES → sage_metal_vm_init()          # wire UART callbacks
│        sage_metal_vm_exec(blob, sz)  # run shell.sgvm
│        if rc != 0 → shell_main()     # C fallback on error
│
└─ NO  → shell_main()                  # built-in C shell
```

---

## Building MetalVM Sources

`sagemake build` compiles MetalVM with the same bare-metal flags as the rest of the kernel:

```bash
riscv64-linux-gnu-gcc \
  -march=rv64imac_zicsr_zifencei -mabi=lp64 \
  -nostdlib -ffreestanding -O2 \
  -DSAGE_BARE_METAL -DSAGE_METAL_VM \
  -I${SAGELANG_CORE}/include \
  -c metal_vm.c -o build/metal_vm.o
```

If `SAGELANG_CORE` is not set, `sagemake setup-metalvm` copies the four source files from the SageLang repo into `kernel/*_bundled.*` for a self-contained build.

---

## Host-Side Testing

Before a full QEMU boot you can test `.sgvm` binaries on the host:

```bash
./sagemake compile-kernel   # kernel/kmain.sage -> kernel/kmain.sgvm
./sagemake run-kernel       # sagevm run kernel/kmain.sgvm

./sagemake compile-shell    # shell/shell.sage  -> shell/shell.sgvm
./sagemake run-shell        # sagevm run shell/shell.sgvm
```

This lets you iterate on Sage code without a cross-compile + QEMU cycle for every change.
