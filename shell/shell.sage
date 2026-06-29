## shell/shell.sage — SageOS-RV Interactive Shell
## Runs as a SageRTOS task. Uses rtos_yield() for cooperative scheduling.

print("[OK] SageRTOS: shell task registered\n")
print("[OK] MetalRV64: shell loaded\n")
print("\nSageOS-RV Shell — type below:\n\n")

proc shell_task():
    print("sage# ")
    let c1 = readline()
    print("You typed: ")
    print(c1)
    print("\n")

    print("sage# ")
    let c2 = readline()
    print("You typed: ")
    print(c2)
    print("\n")

    print("sage# ")
    let c3 = readline()
    print("You typed: ")
    print(c3)
    print("\n")

    print("Shell done.\n")

shell_task()
