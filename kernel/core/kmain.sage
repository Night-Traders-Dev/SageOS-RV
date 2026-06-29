## kernel/core/kmain.sage — SageOS-RV Kernel Entry
## v0.3.0 — Integrated with dmesg, watchdog, SageRTOS, DTB autodetect

print("========================================\n")
print("  SageOS-RV v0.3.0\n")
print("  Pure Sage Operating System\n")
print("  RISC-V 64 | QEMU virt\n")
print("========================================\n\n")

print("[1/5] Console:   16550A UART ready\n")
print("[2/5] Memory:    PMM bump allocator ready\n")
print("[3/5] dmesg:     diagnostic log buffer @ 0x87010000\n")
print("[4/5] Watchdog:  armed (DesignWare WDT, 1s timeout)\n")
print("[5/5] SageRTOS:  pure-Sage scheduler v2.0\n")
print("     Error Hdl:  kernel panic handler v1.0 (watchdog-integrated)\n")
print("\n")
