## shell/shell.sage — SageOS-RV Interactive Shell

print("[OK] MetalRV64: shell loaded\n")
print("\nSageOS-RV Shell — type 'help' for commands\n\n")

let running = true

while running:
    print("sage# ")
    let cmd = readline()
    
    if streq(cmd, ""):
        continue
    
    if streq(cmd, "halt"):
        print("Halting system...\n")
        running = false
    else:
        print("You typed: ")
        print(cmd)
        print("\n")

print("Shell exited.\n")
