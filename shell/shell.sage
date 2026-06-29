## shell/shell.sage — SageOS-RV Interactive Shell

print("[OK] MetalRV64: shell loaded\n")
print("SageOS-RV Shell — type 'halt' to exit\n\n")

let running = true

while running:
    print("sage# ")
    let cmd = readline()
    print("You typed: ")
    print(cmd)
    print("\n")
    
    if streq(cmd, "halt"):
        print("Halting...\n")
        running = false

print("Shell exited.\n")
