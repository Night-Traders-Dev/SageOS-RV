## shell/shell.sage — SageOS-RV Interactive Shell

print("[OK] MetalRV64: shell loaded\n")
print("\nSageOS-RV Shell — type 'help' for commands\n\n")

let running = true

while running:
    print("sage# ")
    let cmd = readline()

    if streq(cmd, ""):
        continue

    let matched = false
    
    if streq(cmd, "help"):
        print("Commands: help, version, about, clear, echo, halt\n")
        matched = true
    
    if streq(cmd, "version"):
        print("SageOS-RV v0.2.0  RISC-V 64  MetalRV64 (Q32.32)\n")
        matched = true
    
    if streq(cmd, "about"):
        print("SageOS-RV: Pure Sage OS for RISC-V 64\n")
        matched = true
    
    if streq(cmd, "clear"):
        print("\e[2J\e[H")
        matched = true
    
    if streq(cmd, "echo"):
        print("echo: type text after echo\n")
        matched = true
    
    if streq(cmd, "halt"):
        print("Halting system...\n")
        running = false
        matched = true

    if matched == false:
        print("Unknown: ")
        print(cmd)
        print("\n")

print("Shell exited.\n")
