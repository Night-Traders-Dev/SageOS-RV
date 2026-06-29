## shell/shell.sage — SageOS-RV Interactive Shell
## Single inline script — no proc definitions.

print("[OK] MetalRV64: shell loaded\n")
print("\nSageOS-RV Shell — type 'help' for commands\n\n")

let running = true

while running:
    print("sage# ")
    let cmd = readline()
    if cmd == "":
        continue

    if cmd == "help":
        print("Commands: help, version, about, clear, echo, halt\n")
    elif cmd == "version":
        print("SageOS-RV v0.2.0  RISC-V 64  MetalRV64 (Q32.32)\n")
    elif cmd == "about":
        print("SageOS-RV: Pure Sage OS for RISC-V 64\n")
        print("Built with SageVM SRVM + MetalRV64 VM\n")
    elif cmd == "clear":
        print("\e[2J\e[H")
    elif cmd == "echo":
        print("echo: type text after echo\n")
    elif cmd == "halt":
        print("Halting system...\n")
        running = false
    else:
        print("Unknown: ")
        print(cmd)
        print("\n")

print("Shell exited.\n")
