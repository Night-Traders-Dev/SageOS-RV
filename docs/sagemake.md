# sagemake — Build System Reference

`sagemake` is the SageOS-RV build system, implemented as a single portable bash script.

## Usage

```bash
./sagemake <command> [options]
```

Environment variables override detected defaults:

| Variable | Default | Description |
|---|---|---|
| `SAGE` | auto-detected | Path to `sage` compiler binary |
| `SAGEVM` | auto-detected | Path to `sagevm` binary |
| `RISCV_CC` | `riscv64-linux-gnu-gcc` | C cross-compiler |
| `RISCV_LD` | `riscv64-linux-gnu-ld` | Linker |
| `RISCV_OBJCOPY` | `riscv64-linux-gnu-objcopy` | objcopy |
| `QEMU_BIN` | `qemu-system-riscv64` | QEMU binary |
| `OPENSBI_FW` | `/usr/lib/riscv64-linux-gnu/opensbi/generic/fw_dynamic.bin` | OpenSBI firmware |
| `BOARD` | `qemu-virt` | Target board |
| `SAGELANG_CORE` | `../SageLang/core` | Path to SageLang core (for MetalVM headers) |
| `SAGEVM_DIR` | `../SageVM` | Path to SageVM repo (for SRVM sources) |

---

## Commands

### `build`

Full build pipeline:

1. Generate boot assembly from `boot/arch/rv64/boot.S`
2. Compile `boot/arch/rv64/boot.S` → `build/boot.o`
3. Build root filesystem (`rootfs.bin`) and embed as `.rootfs` section
4. **`sagevm compile kernel/core/kmain.sage kernel/core/kmain.sgvm --riscv`** (SGRV RISC-V bytecode)
5. **`sagevm compile shell/shell.sage shell/shell.sgvm --riscv`** (SGRV RISC-V bytecode)
6. Embed `kernel/core/kmain.sgvm` → `build/kernel_sgvm.o` (ELF object, section `.sgvm_kernel`)
7. Embed `shell/shell.sgvm` → `build/shell_sgvm.o` (ELF object, section `.sgvm_shell`)
8. Compile SageRTOS (if present)
9. Compile MetalRV64 VM (`metal_rv64_vm_impl.c`) + stack VM (`metal_vm_impl.c`)
10. Compile kernel C (`fallback_kernel.c`), dtb.c, vmm.c with `-nostdlib -ffreestanding`
11. Compile drivers from `drivers/*.sage`
12. Link everything with `linker.ld` → `build/sageos.elf`
13. `objcopy -O binary` → `images/sageos.bin`

```bash
./sagemake build
BOARD=licheerv-nano ./sagemake build
SAGELANG_CORE=/opt/sagelang/core ./sagemake build
```

---

### `compile-kernel`

Compile `kernel/core/kmain.sage` to `kernel/core/kmain.sgvm` using `sagevm compile --riscv`.

```bash
./sagemake compile-kernel
```

Skips gracefully if `sagevm` is not found.

---

### `run-kernel`

Run `kernel/core/kmain.sgvm` directly via `sagevm run --riscv` on the host. Useful for iterating on kernel Sage code without a full QEMU build cycle.

```bash
./sagemake run-kernel
```

---

### `compile-shell`

Compile `shell/shell.sage` to `shell/shell.sgvm` using `sagevm compile --riscv`.

```bash
./sagemake compile-shell
```

---

### `run-shell`

Run `shell/shell.sgvm` directly via `sagevm run --riscv` on the host.

```bash
./sagemake run-shell
```

---

### `qemu`

Launch QEMU with the built kernel. Tries `build/sageos.elf` first, falls back to `images/sageos.bin`.

```bash
./sagemake qemu
```

QEMU flags used:
```
-machine virt -cpu rv64 -smp 1 -m 128M -nographic
-bios <opensbi> -kernel <elf> -serial mon:stdio
```

---

### `build-run`

Runs `build` then `qemu` in sequence.

```bash
./sagemake build-run
```

---

### `clean`

Removes `build/` and `images/sageos.{bin,elf}`. Does not remove `.sgvm` files.

```bash
./sagemake clean
```

---

### `setup-srvm`

Copies SRVM Sage sources from the SageVM repo into `kernel/`:

- `srvm_core.sage`
- `srvm_vm.sage`

```bash
./sagemake setup-srvm
# or with custom path:
SAGEVM_DIR=/path/to/SageVM ./sagemake setup-srvm
```

---

### `setup-metalvm`

Copies MetalVM C sources from `SAGELANG_CORE` into `kernel/*_bundled.*` for self-contained builds (no SageLang checkout required).

```bash
./sagemake setup-metalvm
SAGELANG_CORE=/path/to/SageLang/core ./sagemake setup-metalvm
```

---

### `image`

Creates a 64 MB raw disk image at `images/sageos.img`.

```bash
./sagemake image
```

---

### `test`

Runs all `tests/*.sage` files through `sage --runtime ast`.

```bash
./sagemake test
```

---

### `version`

Prints SageOS-RV version, board, arch, and detected toolchain versions.

```bash
./sagemake version
```

---

## sagevm Auto-Detection

`sagemake` searches for `sagevm` in this order:

1. `$SAGEVM` environment variable
2. `sagevm` on `$PATH`
3. `/home/kraken/Devel/SageVM/sagevm`
4. `/home/kraken/Devel/SageLang/sagevm`
5. `../SageVM/sagevm` (sibling directory)

If none are found, `sagevm`-dependent steps warn and skip — the C transpile path still runs and the build completes.

---

## Typical Workflows

### First build
```bash
./sagemake build-run
```

### Iterate on shell Sage code
```bash
# Edit shell/shell.sage
./sagemake compile-shell   # fast: ~1s
./sagemake run-shell       # test on host
./sagemake build           # embed into kernel image
./sagemake qemu            # boot test
```

### Iterate on kernel Sage code
```bash
# Edit kernel/core/kmain.sage
./sagemake compile-kernel  # fast: ~1s
./sagemake run-kernel      # test on host
./sagemake build-run       # full cycle
```

### CI / headless
```bash
SAGE=sage3 SAGEVM=/opt/sagevm/sagevm ./sagemake build
```
