## drivers/usb/dwc2.sage — Synopsys DesignWare Core (DWC2) USB OTG Driver
##
## Hardware: CV1800B/SG2002 USB 2.0 OTG Controller
## Base Address: 0x04340000

let DWC2_BASE       = 0x04340000
let DWC2_PHY_BASE   = 0x03006000

## Core Global Registers
let GOTGCTL         = 0x000
let GOTGINT         = 0x004
let GAHBCFG         = 0x008
let GUSBCFG         = 0x00C
let GRSTCTL         = 0x010
let GINTSTS         = 0x014
let GINTMSK         = 0x018
let GRXSTSR         = 0x01C
let GRXFSIZ         = 0x024
let GNPTXFSIZ       = 0x028
let GHWCFG1         = 0x044
let GHWCFG2         = 0x048
let GHWCFG3         = 0x04C
let GHWCFG4         = 0x050

## Device Mode Registers
let DCFG            = 0x800
let DCTL            = 0x804
let DSTS            = 0x808
let DIEPMSK         = 0x810
let DOEPMSK         = 0x814
let DAINT           = 0x818
let DAINTMSK        = 0x81C
let DVBUSDIS        = 0x828
let DVBUSPULSE      = 0x82C

## Endpoint 0 Registers
let DIEPCTL0        = 0x900
let DIEPINT0        = 0x908
let DIEPTSIZ0       = 0x910
let DIEPDMA0        = 0x914

let DOEPCTL0        = 0xB00
let DOEPINT0        = 0xB08
let DOEPTSIZ0       = 0xB10
let DOEPDMA0        = 0xB14

## Constants
let GAHBCFG_GLBINTMASK = 0x01
let GRSTCTL_CSFTRST    = 0x01
let GRSTCTL_AHBIDLE    = 0x80000000
let GUSBCFG_PHYIF      = 0x08
let DCFG_DEVSPD_HS     = 0x00
let DCFG_DEVSPD_FS     = 0x03

proc dwc2_read32(offset):
    return mem_read(DWC2_BASE + offset, 4)

proc dwc2_write32(offset, val):
    mem_write(DWC2_BASE + offset, val, 4)

proc dwc2_reset():
    ## Wait for AHB master IDLE
    let timeout = 100000
    while (dwc2_read32(GRSTCTL) & GRSTCTL_AHBIDLE) == 0 and timeout > 0:
        timeout = timeout - 1

    ## Issue core soft reset
    dwc2_write32(GRSTCTL, GRSTCTL_CSFTRST)
    
    timeout = 100000
    while (dwc2_read32(GRSTCTL) & GRSTCTL_CSFTRST) != 0 and timeout > 0:
        timeout = timeout - 1
        
    return true

proc dwc2_init():
    print("usb: Initializing Synopsys DWC2 OTG at 0x04340000...\n")
    
    ## Reset the core
    if not dwc2_reset():
        print("usb: ERROR: DWC2 reset failed or timed out\n")
        return false

    ## Configure PHY
    ## SG2002 uses an internal UTMI+ PHY
    let usblen = dwc2_read32(GUSBCFG)
    dwc2_write32(GUSBCFG, usblen | GUSBCFG_PHYIF)

    ## Initialize as Device Mode (we want to enumerate as a peripheral)
    let dcfg = dwc2_read32(DCFG)
    dcfg = (dcfg & 0xFFFFFFFC) | DCFG_DEVSPD_FS  ## Force Full-Speed for now
    dwc2_write32(DCFG, dcfg)
    
    ## Unmask Global Interrupts
    dwc2_write32(GAHBCFG, GAHBCFG_GLBINTMASK)
    
    ## Unmask USB Reset and Enumeration Done interrupts
    dwc2_write32(GINTMSK, 0x00003000) 
    
    ## Soft Disconnect / Reconnect
    dwc2_write32(DCTL, dwc2_read32(DCTL) & 0xFFFFFFFD) ## Clear SoftDisconnect bit
    
    print("usb: DWC2 initialized in Device Mode\n")
    return true

proc dwc2_ep0_setup():
    ## Configure EP0 to receive SETUP packets
    print("usb: Configuring Endpoint 0 for Control Transfers\n")
    ## Allow 1 SETUP packet, Max Packet Size 64
    dwc2_write32(DOEPTSIZ0, (1 << 29) | (1 << 19) | 64)
    ## Enable EP0 OUT
    dwc2_write32(DOEPCTL0, dwc2_read32(DOEPCTL0) | 0x80000000 | 0x04000000)
    return true

proc dwc2_poll():
    ## Main USB interrupt polling routine
    let intsts = dwc2_read32(GINTSTS)
    if (intsts & 0x1000) != 0:
        print("usb: USB Reset received\n")
        dwc2_write32(GINTSTS, 0x1000)
    if (intsts & 0x2000) != 0:
        print("usb: Enumeration Done\n")
        let speed = (dwc2_read32(DSTS) >> 1) & 0x03
        if speed == 0:
            print("usb: Connected at High-Speed\n")
        else:
            print("usb: Connected at Full-Speed\n")
        dwc2_write32(GINTSTS, 0x2000)
        dwc2_ep0_setup()
