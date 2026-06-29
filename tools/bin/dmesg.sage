print("dmesg: diagnostic log buffer @ 0x87010000\n")
print("========================================\n")

let count = dmesg_count()
let i = 0
while i < count:
    let msg = dmesg_read(i)
    print("["); print(i); print("] "); print(msg); print("\n")
    i = i + 1

print("--- end of dmesg ---\n")
