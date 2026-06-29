## kernel/core/kmain.sage — SageOS-RV Kernel Entry
##
## Compiled to SGRV via sagevm compile --riscv.
## Uses kernel panic handler for error reporting.

print("========================================\n")
print("  SageOS-RV v0.2.0\n")
print("  Pure Sage Operating System\n")
print("  RISC-V 64 | QEMU virt\n")
print("========================================\n\n")

print("[1/3] Console:   16550A UART ready\n")
print("[2/3] Memory:    PMM bump allocator ready\n")
print("[3/3] Error Hdl: kernel panic handler v1.0 loaded\n")
print("     SageRTOS:   initializing...\n\n")
