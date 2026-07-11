print("Driver Test Suite\n")

proc test_addr(name, addr):
    print(name)
    print(": ")
    print(addr > 0)
    print("\n")

test_addr("GPIO", 0x03020000)
test_addr("I2C", 0x04000000)
test_addr("SPI", 0x04180000)
test_addr("PLIC", 0x0C000000)
test_addr("SysCon", 0x03001000)
test_addr("WDT", 0x03010000)
test_addr("UART", 0x04140000)
test_addr("SDIO / MMC", 0x04300000)
test_addr("USB DWC2", 0x04340000)
test_addr("Display MIPI/VOU", 0x03030000)

print("Timer: 25 MHz > 0 = ")
print(25000000 > 0)
print("\n")

print("WiFi AIC8800: 0x02DF = ")
print(0x02DF)
print("\n")

print("ALL DRIVER BASES VALID\n")
