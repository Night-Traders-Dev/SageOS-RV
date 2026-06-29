## shell/shell.sage — SageOS-RV Interactive Shell
## Uses streq() builtin for string comparison (--riscv doesn't support == on strings)

print("[OK] MetalRV64: shell loaded\n")
print("\nSageOS-RV Shell — type 'help' for commands\n\n")

let running = true

while running:
    print("sage# ")
    let cmd = readline()
    if streq(cmd, "") == 1:
        continue

    if streq(cmd, "help") == 1:
        print("Commands: help, version, about, clear, echo, halt\n")
    elif streq(cmd, "version") == 1:
        print("SageOS-RV v0.2.0  RISC-V 64  MetalRV64 (Q32.32)\n")
    elif streq(cmd, "about") == 1:
        print("SageOS-RV: Pure Sage OS for RISC-V 64\n")
        print("Built with SageVM SRVM + MetalRV64 VM\n")
    elif streq(cmd, "clear") == 1:
        print("\e[2J\e[H")
    elif streq(cmd, "echo") == 1:
        print("echo: type text after echo\n")
    elif streq(cmd, "halt") == 1:
        print("Halting system...\n")
        running = false
    else:
        print("Unknown: ")
        print(cmd)
        print("\n")

print("Shell exited.\n")
