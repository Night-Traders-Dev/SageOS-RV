# SageOS-RV Kernel Architecture

## Overview

SageOS-RV boots on RISC-V 64 in S-mode with OpenSBI as the M-mode firmware.
The kernel is loaded at physical address `0x80200000` by OpenSBI's dynamic
firmware loader. Execution begins in `boot.S`, then transitions to the
Sage/C kernel's `sage_kernel_main()`.

## Memory Layout

```
Address         | Size   | Purpose
----------------|--------|-------------------------
0x80000000      | 256 KB | OpenSBI firmware (ROM)
0x80200000      | 128 MB | Kernel + RAM (contiguous)
0x80200000      |   ~1 MB| Kernel .text, .rodata, .data, .bss
0x81000000      |        | Initial stack pointer
0x88200000      |        | End of RAM
```

Physical memory: `0x80200000` to `0x88200000` = 128 MB.

```
+------------------+ 0x80000000
| OpenSBI FW       |
+------------------+ 0x80200000
| Kernel .text     |
| Kernel .rodata   |
| Kernel .data     |
| Kernel .bss      |
+------------------+ 0x81000000
| Stack (grows down)|
| Free memory      |
+------------------+ 0x88200000
```

## Boot Flow

### 1. OpenSBI (M-mode)

- Power-on reset at `0x80000000`
- Initializes platform (clint, uart, pmp)
- Configures PMP regions for S/U access
- Sets `mideleg` / `medeleg` to delegate interrupts and traps to S-mode
- Installs SBI v3.0 handler
- `mret` to `0x80200000` in S-mode

### 2. boot.S (S-mode)

```
_start:
  li   sp, 0x81000000         # Set up C stack
  li   a7, 1; li a0, 'S'; ecall  # SBI putchar 'S'
  li   a7, 1; li a0, 'B'; ecall  # SBI putchar 'B'
  li   a7, 1; li a0, 'I'; ecall  # SBI putchar 'I'

  li   t0, 0x10000000         # UART base
  sb   zero, 1(t0)            # IER = 0 (disable IRQs)
  li   t1, 0x03
  sb   t1, 3(t0)              # LCR = 8N1
  li   t1, 0xC7
  sb   t1, 2(t0)              # FCR = enable FIFO

  # Verify UART by polling LSR.THRE + writing 'K!'
  ...

  # Clear BSS
  la   t0, _bss_start
  la   t1, _bss_end
  bgeu t0, t1, done
  sd   zero, 0(t0)
  addi t0, t0, 8

done:
  call sage_kernel_main       # Enter kernel
```

Key details:
- Uses `sb`/`lbu` (byte) accesses for the 8250 UART registers
- SBI ecall putchar for initial boot messages (guaranteed in S-mode)
- Direct UART init + polling for kernel console

### 3. Kernel Initialization (fallback_kernel.c)

```
sage_kernel_main():
  [1]   uart_init()              → 16550A, byte MMIO
  [2]   metal_rv64_vm_init()     → zero MetalRV64VM pools
  [3]   wire write_char/read_char callbacks
  [4]   metal_rv64_vm_load_binary() → parse SGRV binary
  [5]   for each chunk:           → register function bindings
          metal_rv64_vm_run()
  [6]   shell dispatch           → (when kernel globals are available)
```

## SBI Wrappers

The kernel communicates with OpenSBI via the SBI (Supervisor Binary Interface).
Wrappers are defined in `kernel/sbi.h`.

| Function            | Extension | EID           | FID | Args           |
|---------------------|-----------|---------------|-----|----------------|
| sbi_console_putchar | Legacy    | 0x01          | —   | char           |
| sbi_console_getchar | Legacy    | 0x02          | —   | —              |
| sbi_set_timer       | TIME      | 0x54494D45    | 0   | stime_value    |
| sbi_system_reset    | SRST      | 0x53525354    | 0   | type, reason   |
| sbi_shutdown        | SRST      | 0x53525354    | 0   | SHUTDOWN=0     |
| sbi_cold_reboot     | SRST      | 0x53525354    | 0   | COLD_REBOOT=1  |
| sbi_warm_reboot     | SRST      | 0x53525354    | 0   | WARM_REBOOT=2  |

Calling convention:
- `a7` = extension ID (EID)
- `a6` = function ID (FID)
- `a0`-`a5` = arguments
- Return: `a0` = error code, `a1` = value

## UART Driver

The kernel uses the 16550A-compatible UART at `0x10000000` (QEMU virt).

### Register Map (byte offsets)

| Offset | Register | Access | Description        |
|--------|----------|--------|--------------------|
| 0      | THR/RBR  | W/R    | Transmit / Receive |
| 1      | IER      | W      | Interrupt Enable   |
| 2      | FCR      | W      | FIFO Control       |
| 3      | LCR      | W      | Line Control       |
| 5      | LSR      | R      | Line Status        |

All accesses are **byte-wide** (`volatile uint8_t*`).

## Shell

The shell supports:

| Command    | Description                          |
|------------|--------------------------------------|
| `help`     | List commands                        |
| `version`  | Kernel version + SBI info            |
| `mem`      | Memory statistics (pages, KB)        |
| `uptime`   | Timer ticks since boot               |
| `reboot`   | SBI SRST cold reboot                 |
| `poweroff` | SBI SRST shutdown                    |
| `halt`     | WFI loop (local halt)                |
| `clear`    | ANSI escape clear screen             |
| `echo`     | Print arguments                      |

Input polling interleaves UART `LSR.DR` checks with SBI `console_getchar`
and periodic `timer_poll()` to keep `uptime` accurate.

## Known Issues

### sstatus.SIE is WARL-0 in QEMU 10.2.1

On QEMU's `-cpu rv64` for the `virt` machine, writing to `sstatus` bit 0
(SIE) appears to be silently ignored. The register reads back the same value
regardless of what is written. This means supervisor interrupt delivery via
`stvec` does not work in emulation.

**Workaround**: Poll `SIP.STIP` in the main loop and call the timer handler
directly. This is a QEMU emulation artifact — hardware RISC-V cores do not
exhibit this behavior.

### Kernel Global Initialization

The kernel Sage code (`kmain.sage`) uses `OBJ_GET_GLOBAL` to resolve symbols
like `mem_write`, `UART_BASE`, etc. The MetalRV64 VM currently lacks built-in
global registration — chunks attempting to resolve these globals during sequential
initialization will receive nil values. This requires either:
- Pre-populating the global namespace with kernel builtins before chunk execution
- Adapting the kernel Sage code to not depend on globals at init time

### SageVM --riscv SGRV Format

The SGRV binary format uses `funct3=2` (OBJ_OPS) for object/global operations
with a register-bind convention (VMSYS sub_op=0 copies x10 to rd). The
stack-based MetalVM SGVM format (funct3-based dispatch) is mutually exclusive.
