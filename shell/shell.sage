print("[OK] MetalRV64: shell loaded\n")
print("SageOS-RV Shell — type 'help' for commands\n\n")

while 1:
    print("sage# ")
    let cmd = readline()
    if not streq(cmd, ""):
        if streq(cmd, "exit"):
            break
        run(cmd)

print("Shell done.\n")
