## shell/shell.sage — SageOS-RV Interactive Shell
## Uses direct print(readline()) since let bindings don't work in SGRV

print("[OK] MetalRV64: shell loaded\n")
print("\nSageOS-RV Shell — interactive echo\n\n")

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
