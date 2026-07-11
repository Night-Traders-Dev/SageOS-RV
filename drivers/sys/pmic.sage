## drivers/sys/pmic.sage — SG2002 PMIC / Power Management Driver
##
## Manages the AXP15060 (or compatible) PMIC via I2C0.
## Sets voltage rails for CPU core, DDR, IO, and WiFi.
##
## I2C address: 0x34 (7-bit) for AXP15060 on LicheeRV Nano

let PMIC_I2C_BUS  = 0
let PMIC_I2C_ADDR = 0x34

## AXP15060 register map
let PMIC_POWER_ON_CTRL  = 0x00
let PMIC_VSET_CPU       = 0x01
let PMIC_VSET_DDR       = 0x02
let PMIC_VSET_IO        = 0x03
let PMIC_VSET_WIFI      = 0x04
let PMIC_STATUS         = 0x10
let PMIC_CHIP_ID        = 0x20

proc pmic_read8(reg):
    i2c_write(PMIC_I2C_BUS, PMIC_I2C_ADDR, reg, 1)
    return i2c_read(PMIC_I2C_BUS, PMIC_I2C_ADDR, 1)

proc pmic_write8(reg, val):
    i2c_write(PMIC_I2C_BUS, PMIC_I2C_ADDR, reg, 1)
    i2c_write(PMIC_I2C_BUS, PMIC_I2C_ADDR, val, 1)

proc pmic_init():
    print("[PMIC] Initializing AXP15060 power management...\n")

    i2c_init(PMIC_I2C_BUS, 400000)

    let chip_id = pmic_read8(PMIC_CHIP_ID)
    print("[PMIC] Chip ID: 0x")
    print(chip_id)
    print("\n")

    let status = pmic_read8(PMIC_STATUS)
    print("[PMIC] Status: 0x")
    print(status)
    print("\n")

    let power_ctrl = pmic_read8(PMIC_POWER_ON_CTRL)
    if power_ctrl != 0xFF:
        pmic_write8(PMIC_POWER_ON_CTRL, 0xFF)
        print("[PMIC] Power-on control set to 0xFF (all rails enabled)\n")

    print("[PMIC] PMIC initialized.\n")
    return true

proc pmic_set_cpu_voltage(mv):
    let vset = (mv - 600) / 10
    if vset > 0x7F: vset = 0x7F
    if vset < 0: vset = 0
    pmic_write8(PMIC_VSET_CPU, vset)
    print("[PMIC] CPU voltage set to ")
    print(mv)
    print(" mV (0x")
    print(vset)
    print(")\n")

proc pmic_set_wifi_voltage(mv):
    let vset = (mv - 600) / 10
    if vset > 0x7F: vset = 0x7F
    if vset < 0: vset = 0
    pmic_write8(PMIC_VSET_WIFI, vset)
    print("[PMIC] WiFi voltage set to ")
    print(mv)
    print(" mV\n")
