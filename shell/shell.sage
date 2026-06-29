## shell/shell.sage — SageOS-RV Interactive Shell
## Uses native string comparison (== works in SGRV now)

print("[OK] MetalRV64: shell loaded\n")
print("SageOS-RV Shell — type 'help' for commands\n\n")

let running = true

while running:
    print("sage# ")
    let cmd = readline()
    if cmd == "":
        continue
    if cmd == "help":
        print("Commands: help version about clear dmesg ls mem ps halt\n")
    elif cmd == "version":
        print("SageOS-RV v0.3.0  RISC-V 64  MetalRV64 (Q32.32)\n")
    elif cmd == "about":
        print("SageOS-RV: Pure Sage OS for RISC-V 64\n")
    elif cmd == "clear":
        print("\e[2J\e[H")
    elif cmd == "dmesg":
        print("dmesg: log buffer at 0x87010000 (256 messages, 32KB)\n")
    elif cmd == "ls":
        print("/welcome.txt (95 bytes)\n")
    elif cmd == "mem":
        print("Memory: PMM bump allocator, 256 pages (1 MiB arena)\n")
    elif cmd == "ps":
        print("PID  NAME        STATE\n  0  shell       RUNNING\n")
    elif cmd == "halt":
        print("Halting system...\n")
        running = false
    else:
        print("Unknown: ")
        print(cmd)
        print("\n")

print("Shell exited.\n")
