import os

bin_dir = "tools/bin"

replacements = {
    "pwd.sage": 'print("/\\n")\n',
    "halt.sage": 'print("Halting system...\\n")\nrun("halt")\n',
    "wdog.sage": 'print("Watchdog — DesignWare WDT @ 0x03010000\\n")\nprint("Kicking watchdog...\\n")\nwdog_kick()\nprint("Watchdog kicked successfully.\\n")\n',
    "gpio.sage": 'print("GPIO Status\\n")\nlet val = mem_read(0x03020000, 4)\nprint("GPIO0 State: ")\nprint(val)\nprint("\\n")\n',
    "i2c.sage": 'print("I2C Bus Scan\\n")\nlet stat = mem_read(0x04000000, 4)\nprint("I2C0 IC_CON: ")\nprint(stat)\nprint("\\n")\n',
    "uptime.sage": 'print("System Uptime\\n")\nlet mtime = mem_read(0x0200BFF8, 8)\nprint("Ticks (10MHz): ")\nprint(mtime)\nprint("\\n")\n',
    "dmesg.sage": 'let count = dmesg_count()\nlet i = 0\nwhile i < count:\n    let line = dmesg_read(i)\n    if not streq(line, ""):\n        print(line)\n        print("\\n")\n    i = i + 1\n',
}

for root, dirs, files in os.walk(bin_dir):
    for file in files:
        if file.endswith(".sage"):
            path = os.path.join(root, file)
            if file in replacements:
                with open(path, "w") as f:
                    f.write(replacements[file])
            else:
                # Basic functional skeleton for others
                pass

print("Updated tools/bin files.")
replacements = {
    "net.sage": 'print("Network Interface Status\\n")\nlet mac = mem_read(0x04300000, 4)\nprint("MAC Hash: ")\nprint(mac)\nprint("\\n")\n',
    "spi.sage": 'print("SPI Bus Status\\n")\nlet stat = mem_read(0x04001000, 4)\nprint("SPI0 SR: ")\nprint(stat)\nprint("\\n")\n',
    "wifi.sage": 'print("WiFi Driver (AIC8800D)\\n")\nlet fw_sz = aic8800_load_fw()\nprint("Loaded FW Size: ")\nprint(fw_sz)\nprint(" bytes\\n")\n',
}

for file, content in replacements.items():
    path = os.path.join("tools/bin", file)
    with open(path, "w") as f:
        f.write(content)

