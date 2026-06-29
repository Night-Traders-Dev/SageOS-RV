## shell/shell.sage — SageOS-RV Interactive Shell
##
## Compiled to SGRV via sagevm compile --riscv.

let SHELL_VERSION = "0.2.0"
let shell_running = true

proc shell_main():
    print("[OK] SageRTOS: shell task registered\n")
    print("[OK] MetalRV64: shell loaded\n\n")
    print("SageOS-RV Shell — type 'help' for commands\n\n")

    while shell_running:
        print("sage# ")
        let cmd = readline()
        if cmd == "":
            continue
        if cmd == "help":
            shell_cmd_help()
        elif cmd == "version":
            shell_cmd_version()
        elif cmd == "about":
            shell_cmd_about()
        elif cmd == "clear":
            print("\e[2J\e[H")
        elif cmd == "echo":
            print("echo: type something after echo\n")
        elif cmd == "halt":
            shell_cmd_halt()
        else:
            print("Unknown command: ")
            print(cmd)
            print("\nType 'help' for available commands\n\n")

    print("Shell exited.\n")

proc shell_cmd_help():
    print("Available commands:\n")
    print("  help     Show this help\n")
    print("  version  Show kernel version\n")
    print("  about    About SageOS\n")
    print("  clear    Clear screen\n")
    print("  echo     Echo text\n")
    print("  halt     Halt the system\n\n")

proc shell_cmd_version():
    print("SageOS-RV v")
    print(SHELL_VERSION)
    print("\nKernel: SageOS-RV\nArch: RISC-V 64 (rv64imac)\nVM: MetalRV64 (Q32.32 fixed-point)\n\n")

proc shell_cmd_about():
    print("SageOS-RV: Pure Sage Operating System for RISC-V 64\n")
    print("Built with SageVM SRVM + MetalRV64 VM\n")
    print("Target: QEMU virt / LicheeRV Nano\n")
    print("Repository: github.com/Night-Traders-Dev/SageOS-RV\n\n")

proc shell_cmd_halt():
    print("Halting system...\n")
    shell_running = false

shell_main()
