let count = dmesg_count()
let i = 0
while i < count:
    let line = dmesg_read(i)
    if not streq(line, ""):
        print(line)
        print("\n")
    i = i + 1
