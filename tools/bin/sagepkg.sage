## tools/bin/sagepkg.sage — SageOS Package Manager
##
## Manages tool binaries from rootfs. Install/remove/list.
## Packages are .sgvm files in rootfs/bin/.

print("sagepkg — SageOS Package Manager\n")
print("========================================\n")
print("\n")
print("Installed packages:\n")
print("  help      version   about     clear\n")
print("  dmesg     ls        mem       ps\n")
print("  halt      ssh       wifi      i2c\n")
print("  gpio      spi       net       wdog\n")
print("  uptime    rtos      sagefetch uname\n")
print("  whoami    df        free      kill\n")
print("  ping      curl      ip        pwd\n")
print("  cd        cat       grep      find\n")
print("  cp        mv        rm        touch\n")
print("  less      chmod     sudo      sagepkg\n")
print("\nUsage:\n")
print("  sagepkg list             — list installed packages\n")
print("  sagepkg install <name>   — install from rootfs or network\n")
print("  sagepkg remove <name>    — remove a package\n")
print("  sagepkg update           — update all packages\n")
print("\n43 packages installed\n")
