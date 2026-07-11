/* kernel/drivers/usb_cdc_acm.c
 * DWC2 USB CDC ACM Gadget — LicheeRV Nano (SG2002)
 *
 * Presents the board as a USB virtual serial port (ttyACM0 on host).
 * Implemented at the register level for the Synopsys DWC2 OTG core.
 */

#include <stdint.h>
#include <stddef.h>
#include "usb_cdc_acm.h"

/* =========================================================================
 * DWC2 Register Offsets (same as drivers/usb/dwc2.sage)
 * ========================================================================= */
#define DWC2_BASE       0x04340000UL

/* Core Global */
#define GOTGCTL         0x000
#define GOTGINT         0x004
#define GAHBCFG         0x008
#define GUSBCFG         0x00C
#define GRSTCTL         0x010
#define GINTSTS         0x014
#define GINTMSK         0x018
#define GRXSTSR         0x01C
#define GRXSTSP         0x020
#define GRXFSIZ         0x024
#define GNPTXFSIZ       0x028
#define GNPTXSTS        0x02C
#define GHWCFG2         0x048
#define GHWCFG4         0x050

/* Device Mode */
#define DCFG            0x800
#define DCTL            0x804
#define DSTS            0x808
#define DIEPMSK         0x810
#define DOEPMSK         0x814
#define DAINT           0x818
#define DAINTMSK        0x81C

/* EP0 IN */
#define DIEPCTL0        0x900
#define DIEPINT0        0x908
#define DIEPTSIZ0       0x910
#define DIEPDMA0        0x914

/* EP0 OUT */
#define DOEPCTL0        0xB00
#define DOEPINT0        0xB08
#define DOEPTSIZ0       0xB10
#define DOEPDMA0        0xB14

/* EP1 IN (Interrupt — CDC notification) */
#define DIEPCTL1        0x920
#define DIEPINT1        0x928
#define DIEPTSIZ1       0x930
#define DIEPDMA1        0x934

/* EP2 IN (Bulk TX — serial data to host) */
#define DIEPCTL2        0x940
#define DIEPINT2        0x948
#define DIEPTSIZ2       0x950
#define DIEPDMA2        0x954

/* EP2 OUT (Bulk RX — serial data from host) */
#define DOEPCTL2        0xB40
#define DOEPINT2        0xB48
#define DOEPTSIZ2       0xB50
#define DOEPDMA2        0xB54

/* FIFO Data Port */
#define DFIFO_BASE      0x1000

/* =========================================================================
 * Bitfield constants
 * ========================================================================= */
/* GAHBCFG */
#define GAHBCFG_GLBLINTR   (1 << 0)
#define GAHBCFG_DMAEN      (1 << 5)

/* GUSBCFG */
#define GUSBCFG_PHYIF      (1 << 3)
#define GUSBCFG_TOUTCAL    0x0F00
#define GUSBCFG_TOUTCAL_SHIFT 8

/* GRSTCTL */
#define GRSTCTL_CSFTRST    (1 << 0)
#define GRSTCTL_AHBIDLE    (1 << 31)
#define GRSTCTL_TXFFLSH    (1 << 5)
#define GRSTCTL_TXFNUM     0x1F00
#define GRSTCTL_TXFNUM_SHIFT 8
#define GRSTCTL_RXFFLSH    (1 << 4)

/* GINTSTS / GINTMSK */
#define GINT_OEPINT       (1 << 19)
#define GINT_IEPINT       (1 << 18)
#define GINT_RXFLVL       (1 << 4)
#define GINT_USBRST       (1 << 12)
#define GINT_ENUMDONE     (1 << 13)
#define GINT_WKUP         (1 << 31)
#define GINT_OTGINT       (1 << 2)

/* DCTL */
#define DCTL_SFTDISCON    (1 << 0)
#define DCTL_CGINAK       (1 << 1)
#define DCTL_SGINAK       (1 << 2)
#define DCTL_POPRGDNE     (1 << 11)

/* DCFG */
#define DCFG_DEVSPD_FS    0x03
#define DCFG_DEVSPD_HS    0x00
#define DCFG_DEVADDR      0x7F00
#define DCFG_DEVADDR_SHIFT 8

/* DSTS */
#define DSTS_SPDSTS       (3 << 1)
#define DSTS_SPDSTS_FS    (3 << 1)
#define DSTS_SPDSTS_HS    (0 << 1)
#define DSTS_ENUMSPD      (3 << 1)

/* DIEPCTL0 / DOEPCTL0 */
#define EPCTL_MPS         0x7FF
#define EPCTL_MPS0_64     (3 << 0)
#define EPCTL_USBAEP      (1 << 15)
#define EPCTL_EPENA       (1 << 31)
#define EPCTL_CNAK        (1 << 26)
#define EPCTL_SNAK        (1 << 27)
#define EPCTL_SETD0PID    (1 << 28)
#define EPCTL_STALL       (1 << 21)
#define EPCTL_NZTXSTPHS   (1 << 22)
#define EPCTL_TYPE        (3 << 18)
#define EPCTL_TYPE_CTRL   0
#define EPCTL_TYPE_BULK   (2 << 18)
#define EPCTL_TYPE_INTR   (3 << 18)

/* DIEPINT / DOEPINT */
#define EPINT_XFERCOMPL   (1 << 0)
#define EPINT_EPDISBLD    (1 << 1)
#define EPINT_AHBERR      (1 << 2)
#define EPINT_SETUP       (1 << 3)
#define EPINT_OUTTKNEPDIS (1 << 4)
#define EPINT_TXFE        (1 << 7)
#define EPINT_NAKEFF      (1 << 19)

/* DIEPTSIZ / DOEPTSIZ */
#define TSIZ_XFERSIZE    0x7FFFF
#define TSIZ_PKTCNT      0x3F80000
#define TSIZ_PKTCNT_SHIFT 19
#define TSIZ_SUPCNT      0xC0000000
#define TSIZ_SUPCNT_1    (1 << 29)
#define TSIZ_SUPCNT_2    (2 << 29)
#define TSIZ_SUPCNT_3    (3 << 29)

/* GRXSTSP (device mode) */
#define RXSTSP_CHNUM     0x0F
#define RXSTSP_BCNT      0x7FF0
#define RXSTSP_BCNT_SHIFT 4
#define RXSTSP_PKTSTS    0xF000
#define RXSTSP_PKTSTS_SHIFT 12
#define RXSTSP_PKTSTS_SETUP      0x02
#define RXSTSP_PKTSTS_OUT        0x03
#define RXSTSP_PKTSTS_SETUPCOMP  0x04

/* DIEPTXF — periodic TX FIFO sizing */
#define DIEPTXF1         0x904
#define DIEPTXF2         0x908
#define DIEPTXF3         0x90C
#define DIEPTXF4         0x910
#define DIEPTXF5         0x914

/* =========================================================================
 * USB Standard Constants
 * ========================================================================= */
#define USB_REQ_GET_STATUS          0x00
#define USB_REQ_CLEAR_FEATURE       0x01
#define USB_REQ_SET_FEATURE         0x03
#define USB_REQ_SET_ADDRESS         0x05
#define USB_REQ_GET_DESCRIPTOR      0x06
#define USB_REQ_SET_DESCRIPTOR      0x07
#define USB_REQ_GET_CONFIGURATION   0x08
#define USB_REQ_SET_CONFIGURATION   0x09
#define USB_REQ_GET_INTERFACE       0x0A
#define USB_REQ_SET_INTERFACE       0x0B

#define DT_DEVICE       1
#define DT_CONFIG       2
#define DT_STRING       3
#define DT_INTERFACE    4
#define DT_ENDPOINT     5
#define DT_DEVICE_QUAL  6
#define DT_OTHER_SPEED  7
#define DT_IFACE_POWER  8

#define CDC_REQ_SET_LINE_CODING         0x20
#define CDC_REQ_GET_LINE_CODING         0x21
#define CDC_REQ_SET_CONTROL_LINE_STATE  0x22
#define CDC_REQ_SEND_BREAK              0x23

/* =========================================================================
 * USB CDC ACM Descriptors
 * ========================================================================= */
#define STR_LANG        0
#define STR_MANUF       1
#define STR_PRODUCT     2
#define STR_SERIAL      3

static const uint8_t dev_desc[] = {
    18,          DT_DEVICE,          /* bLength, bDescriptorType */
    0x00, 0x02,                      /* bcdUSB 2.00 */
    0x02,                            /* bDeviceClass: CDC */
    0x00,                            /* bDeviceSubClass */
    0x00,                            /* bDeviceProtocol */
    64,                              /* bMaxPacketSize0 */
    0x1D, 0x6B,                      /* idVendor: Linux Foundation (placeholder) */
    0x01, 0x04,                      /* idProduct: CDC ACM */
    0x00, 0x00,                      /* bcdDevice */
    1,                               /* iManufacturer */
    2,                               /* iProduct */
    3,                               /* iSerialNumber */
    1,                               /* bNumConfigurations */
};

static const uint8_t config_desc[] = {
    /* Configuration */
    9, DT_CONFIG,
    67, 0,                           /* wTotalLength */
    2,                               /* bNumInterfaces */
    1,                               /* bConfigurationValue */
    0,                               /* iConfiguration */
    0x80,                            /* bmAttributes: Bus Powered */
    50,                              /* bMaxPower: 100mA */
    /* Interface 0 — Communication Interface */
    9, DT_INTERFACE,
    0,                               /* bInterfaceNumber */
    0,                               /* bAlternateSetting */
    1,                               /* bNumEndpoints */
    0x02,                            /* bInterfaceClass: CDC */
    0x02,                            /* bInterfaceSubClass: ACM */
    0x01,                            /* bInterfaceProtocol: AT */
    0,                               /* iInterface */
    /* CDC Header Functional Descriptor */
    5, 0x24, 0x00, 0x10, 0x01,
    /* CDC Call Management Functional Descriptor */
    5, 0x24, 0x01, 0x03, 0x01,
    /* CDC ACM Functional Descriptor */
    4, 0x24, 0x02, 0x06,
    /* CDC Union Functional Descriptor */
    5, 0x24, 0x06, 0x00, 0x01,
    /* Interrupt IN Endpoint (EP1, notifications) */
    7, DT_ENDPOINT,
    0x81,                            /* bEndpointAddress: IN, EP1 */
    0x03,                            /* bmAttributes: Interrupt */
    64, 0,                           /* wMaxPacketSize */
    16,                              /* bInterval */
    /* Interface 1 — Data Interface */
    9, DT_INTERFACE,
    1,                               /* bInterfaceNumber */
    0,                               /* bAlternateSetting */
    2,                               /* bNumEndpoints */
    0x0A,                            /* bInterfaceClass: CDC Data */
    0x00, 0x00, 0x00,                /* sub/proto/i */
    /* Bulk IN Endpoint (EP2, TX data to host) */
    7, DT_ENDPOINT,
    0x82,                            /* bEndpointAddress: IN, EP2 */
    0x02,                            /* bmAttributes: Bulk */
    64, 0,                           /* wMaxPacketSize */
    0,                               /* bInterval */
    /* Bulk OUT Endpoint (EP2, RX data from host) */
    7, DT_ENDPOINT,
    0x02,                            /* bEndpointAddress: OUT, EP2 */
    0x02,                            /* bmAttributes: Bulk */
    64, 0,                           /* wMaxPacketSize */
    0,                               /* bInterval */
};

static const uint8_t str_lang[]    = { 4, DT_STRING, 0x09, 0x04 }; /* LANGID: English */
static const uint8_t str_manuf[]   = { 16, DT_STRING, 'S','a','g','e','O','S','-','R','V',0,0 };
static const uint8_t str_product[] = { 22, DT_STRING, 'L','i','c','h','e','e','R','V',' ','N','a','n','o',' ','W',0,0 };
static const uint8_t str_serial[]  = { 12, DT_STRING, '0','0','0','0','0','1',0,0 };

/* =========================================================================
 * Setup Packet
 * ========================================================================= */
struct usb_setup {
    uint8_t  bmRequestType;
    uint8_t  bRequest;
    uint16_t wValue;
    uint16_t wIndex;
    uint16_t wLength;
};

/* =========================================================================
 * State
 * ========================================================================= */
enum usb_dev_state {
    USB_STATE_DISCONNECTED,
    USB_STATE_RESET,
    USB_STATE_DEFAULT,   /* after reset, before address assigned */
    USB_STATE_ADDRESS,   /* after SET_ADDRESS */
    USB_STATE_CONFIGURED,/* after SET_CONFIGURATION */
};

static enum usb_dev_state usb_state = USB_STATE_DISCONNECTED;
static uint8_t  ep0_buf[64];
static int      ep0_buf_len;
static int      ep0_buf_ptr;
static int      configured = 0;

/* CDC ACM line coding */
static uint32_t line_dterate     = 115200;
static uint8_t  line_charformat  = 0; /* 1 stop bit */
static uint8_t  line_paritytype  = 0; /* none */
static uint8_t  line_databits    = 8;
static uint8_t  control_line_state = 0;

/* TX/RX ring buffers (serial data to/from host) */
#define USB_BUF_SIZE 256
static uint8_t tx_buf[USB_BUF_SIZE];
static volatile int tx_head, tx_tail;
static uint8_t rx_buf[USB_BUF_SIZE];
static volatile int rx_head, rx_tail;

/* Boot log ring (persistent across warm reboot via dmesg region) */
#define BOOTLOG_BASE   0x87010000UL
#define BOOTLOG_MAGIC  0x424C4F47UL /* "BLOG" */
#define BOOTLOG_MAX    64
#define BOOTLOG_LEN    128
static uint8_t bootlog_ready = 0;

/* =========================================================================
 * DWC2 Register Access
 * ========================================================================= */
static inline uint32_t dwc2_r32(uint32_t off) {
    return *(volatile uint32_t *)(uintptr_t)(DWC2_BASE + off);
}
static inline void dwc2_w32(uint32_t off, uint32_t v) {
    *(volatile uint32_t *)(uintptr_t)(DWC2_BASE + off) = v;
}
static inline void dwc2_fifo_w32(uint32_t v) {
    *(volatile uint32_t *)(uintptr_t)(DWC2_BASE + DFIFO_BASE) = v;
}
static inline uint32_t dwc2_fifo_r32(void) {
    return *(volatile uint32_t *)(uintptr_t)(DWC2_BASE + DFIFO_BASE);
}
static void dwc2_busywait(uint32_t count) {
    for (volatile uint32_t i = 0; i < count; i++);
}

/* =========================================================================
 * UART Console Output (used when USB not yet configured)
 * ========================================================================= */
#define UART_BASE_LOCAL 0x04140000UL
#define UART_THR   0
#define UART_LSR   5
#define UART_THRE  0x20
static void uart_putc_local(char c) {
    while ((*(volatile uint8_t *)(UART_BASE_LOCAL + UART_LSR) & UART_THRE) == 0);
    *(volatile uint8_t *)(UART_BASE_LOCAL + UART_THR) = (uint8_t)c;
}
static void uart_puts_local(const char *s) {
    while (*s) uart_putc_local(*s++);
}

/* =========================================================================
 * FIFO Helpers
 * ========================================================================= */
static void ep0_write_fifo(const uint8_t *data, int len) {
    int words = (len + 3) / 4;
    for (int i = 0; i < words; i++) {
        uint32_t w = 0;
        w |= (i*4 + 0 < len) ? ((uint32_t)data[i*4 + 0] << 0) : 0;
        w |= (i*4 + 1 < len) ? ((uint32_t)data[i*4 + 1] << 8) : 0;
        w |= (i*4 + 2 < len) ? ((uint32_t)data[i*4 + 2] << 16) : 0;
        w |= (i*4 + 3 < len) ? ((uint32_t)data[i*4 + 3] << 24) : 0;
        dwc2_fifo_w32(w);
    }
}

static void ep0_read_setup(struct usb_setup *s) {
    uint32_t w0 = dwc2_fifo_r32();
    uint32_t w1 = dwc2_fifo_r32();
    s->bmRequestType = w0 & 0xFF;
    s->bRequest      = (w0 >> 8) & 0xFF;
    s->wValue        = (w0 >> 16) & 0xFFFF;
    s->wIndex        = w1 & 0xFFFF;
    s->wLength       = (w1 >> 16) & 0xFFFF;
}

/* =========================================================================
 * DWC2 Core: Soft Reset & Flush
 * ========================================================================= */
static void dwc2_flush_tx(int epnum) {
    dwc2_w32(GRSTCTL, GRSTCTL_TXFFLSH | (epnum << 8));
    dwc2_busywait(5000);
    while (dwc2_r32(GRSTCTL) & GRSTCTL_TXFFLSH);
}

static void dwc2_flush_rx(void) {
    dwc2_w32(GRSTCTL, GRSTCTL_RXFFLSH);
    dwc2_busywait(5000);
    while (dwc2_r32(GRSTCTL) & GRSTCTL_RXFFLSH);
}

/* =========================================================================
 * Endpoint Configuration
 * ========================================================================= */
static void ep0_activate(void) {
    /* Configure EP0 IN */
    dwc2_w32(DIEPCTL0, 0);
    dwc2_w32(DIEPTSIZ0, 0);
    dwc2_w32(DIEPCTL0, EPCTL_MPS0_64 | EPCTL_USBAEP | EPCTL_SETD0PID);
    /* Configure EP0 OUT */
    dwc2_w32(DOEPCTL0, 0);
    dwc2_w32(DOEPTSIZ0, 0);
    /* Allow 3 SETUP packets, packet count 1, transfer size 64 */
    dwc2_w32(DOEPTSIZ0, TSIZ_SUPCNT_3 | (1 << 19) | 64);
    dwc2_w32(DOEPCTL0, EPCTL_MPS0_64 | EPCTL_USBAEP | EPCTL_EPENA);
}

/* =========================================================================
 * EP0 Control Transfer Handlers
 * ========================================================================= */
static void ep0_send_data(const uint8_t *data, int len) {
    if (len > 64) len = 64;
    ep0_write_fifo(data, len);
    dwc2_w32(DIEPTSIZ0, (1 << 19) | len);
    dwc2_w32(DIEPCTL0, dwc2_r32(DIEPCTL0) | EPCTL_EPENA | EPCTL_CNAK);
}

static void ep0_send_zlp(void) {
    dwc2_w32(DIEPTSIZ0, (1 << 19) | 0);
    dwc2_w32(DIEPCTL0, dwc2_r32(DIEPCTL0) | EPCTL_EPENA | EPCTL_CNAK);
}

static void ep0_set_stall(void) {
    dwc2_w32(DIEPCTL0, dwc2_r32(DIEPCTL0) | EPCTL_STALL);
    dwc2_w32(DOEPCTL0, dwc2_r32(DOEPCTL0) | EPCTL_STALL);
}

static void ep0_receive(void) {
    dwc2_w32(DOEPTSIZ0, TSIZ_SUPCNT_1 | (1 << 19) | 64);
    dwc2_w32(DOEPCTL0, dwc2_r32(DOEPCTL0) | EPCTL_EPENA | EPCTL_CNAK);
}

/* =========================================================================
 * Standard Request Handler
 * ========================================================================= */
static void handle_get_descriptor(uint16_t wValue, uint16_t wIndex, uint16_t wLength) {
    int type  = (wValue >> 8) & 0xFF;
    int index = wValue & 0xFF;
    (void)wIndex;
    int len = 0;
    const uint8_t *data = 0;

    switch (type) {
    case DT_DEVICE:
        data = dev_desc; len = dev_desc[0];
        break;
    case DT_CONFIG:
        data = config_desc; len = config_desc[2] | (config_desc[3] << 8);
        break;
    case DT_STRING:
        switch (index) {
        case STR_LANG:   data = str_lang;   len = str_lang[0];   break;
        case STR_MANUF:  data = str_manuf;  len = str_manuf[0];  break;
        case STR_PRODUCT:data = str_product;len = str_product[0]; break;
        case STR_SERIAL: data = str_serial; len = str_serial[0];  break;
        }
        break;
    case DT_DEVICE_QUAL:
    case DT_OTHER_SPEED:
        /* Not supported — return error */
        ep0_set_stall();
        return;
    }
    if (!data) { ep0_set_stall(); return; }
    if (len > wLength) len = wLength;
    ep0_send_data(data, len);
}

static void handle_set_address(uint16_t addr) {
    uint32_t dcfg = dwc2_r32(DCFG) & ~DCFG_DEVADDR;
    dcfg |= (addr << DCFG_DEVADDR_SHIFT) & DCFG_DEVADDR;
    dwc2_w32(DCFG, dcfg);
    usb_state = USB_STATE_ADDRESS;
    ep0_send_zlp();
}

static void handle_set_configuration(uint16_t config) {
    if (config != 1) { ep0_set_stall(); return; }
    configured = 1;
    usb_state = USB_STATE_CONFIGURED;
    /* Configure EP1 IN: Interrupt (CDC notifications) */
    dwc2_w32(DIEPCTL1, 0);
    dwc2_w32(DIEPTSIZ1, 0);
    dwc2_w32(DIEPCTL1, EPCTL_USBAEP | EPCTL_SETD0PID | EPCTL_TYPE_INTR | 64);
    /* Configure EP2 IN: Bulk (TX data) */
    dwc2_w32(DIEPCTL2, 0);
    dwc2_w32(DIEPTSIZ2, 0);
    dwc2_w32(DIEPCTL2, EPCTL_USBAEP | EPCTL_SETD0PID | EPCTL_TYPE_BULK | 64);
    /* Configure EP2 OUT: Bulk (RX data) */
    dwc2_w32(DOEPCTL2, 0);
    dwc2_w32(DOEPTSIZ2, 0);
    dwc2_w32(DOEPTSIZ2, (1 << 19) | 64);
    dwc2_w32(DOEPCTL2, EPCTL_USBAEP | EPCTL_SETD0PID | EPCTL_TYPE_BULK | EPCTL_EPENA | 64);
    /* Enable EP1 and EP2 IN interrupts */
    uint32_t daint = dwc2_r32(DAINTMSK);
    daint |= (1 << 1) | (1 << 2); /* EP1 IN, EP2 IN */
    daint |= (1 << 17) | (1 << 18); /* EP1 OUT, EP2 OUT */
    dwc2_w32(DAINTMSK, daint);
    ep0_send_zlp();
}

/* =========================================================================
 * CDC ACM Class Request Handler
 * ========================================================================= */
static void handle_cdc_request(struct usb_setup *s) {
    switch (s->bRequest) {
    case CDC_REQ_SET_LINE_CODING: {
        /* Host is sending 7 bytes of line coding data */
        ep0_buf_len = s->wLength;
        ep0_buf_ptr = 0;
        ep0_receive();
        break;
    }
    case CDC_REQ_GET_LINE_CODING: {
        uint8_t lc[7];
        lc[0] = line_dterate & 0xFF;
        lc[1] = (line_dterate >> 8) & 0xFF;
        lc[2] = (line_dterate >> 16) & 0xFF;
        lc[3] = (line_dterate >> 24) & 0xFF;
        lc[4] = line_charformat;
        lc[5] = line_paritytype;
        lc[6] = line_databits;
        ep0_send_data(lc, 7);
        break;
    }
    case CDC_REQ_SET_CONTROL_LINE_STATE:
        control_line_state = s->wValue & 0xFF;
        ep0_send_zlp();
        break;
    case CDC_REQ_SEND_BREAK:
        ep0_send_zlp();
        break;
    default:
        ep0_set_stall();
        break;
    }
}

/* =========================================================================
 * EP0 SETUP Dispatcher
 * ========================================================================= */
static void handle_setup_packet(struct usb_setup *s) {
    int dir_in = (s->bmRequestType & 0x80) != 0;
    int type   = (s->bmRequestType >> 5) & 3;
    int recip  = s->bmRequestType & 0x1F;

    if (type == 0) { /* Standard */
        switch (s->bRequest) {
        case USB_REQ_GET_DESCRIPTOR:
            handle_get_descriptor(s->wValue, s->wIndex, s->wLength);
            return;
        case USB_REQ_SET_ADDRESS:
            handle_set_address(s->wValue);
            return;
        case USB_REQ_SET_CONFIGURATION:
            handle_set_configuration(s->wValue);
            return;
        case USB_REQ_GET_CONFIGURATION: {
            uint8_t cfg = configured ? 1 : 0;
            ep0_send_data(&cfg, 1);
            return;
        }
        case USB_REQ_GET_STATUS: {
            uint8_t sts[2] = {0, 0};
            ep0_send_data(sts, 2);
            return;
        }
        case USB_REQ_GET_INTERFACE: {
            uint8_t iface = 0;
            ep0_send_data(&iface, 1);
            return;
        }
        case USB_REQ_SET_INTERFACE:
            ep0_send_zlp();
            return;
        case USB_REQ_CLEAR_FEATURE:
        case USB_REQ_SET_FEATURE:
            if (recip == 0) { /* Device */
                ep0_send_zlp();
                return;
            }
            if (recip == 2) { /* Endpoint */
                /* For now, handle endpoint halt clear */
                ep0_send_zlp();
                return;
            }
            ep0_set_stall();
            return;
        default:
            ep0_set_stall();
            return;
        }
    } else if (type == 1) { /* Class */
        if (recip == 1) { /* Interface */
            handle_cdc_request(s);
            return;
        }
    }
    ep0_set_stall();
}

/* =========================================================================
 * Receive DATA from EP0 OUT (after SET_LINE_CODING etc.)
 * ========================================================================= */
static void ep0_complete_out(void) {
    if (ep0_buf_ptr == 0 && ep0_buf_len == 0) {
        /* ZLP status */
        ep0_send_zlp();
        return;
    }
    /* Data was received into ep0_buf via rxflvl handling */
    if (ep0_buf_ptr >= 7 && ep0_buf_len >= 7) {
        /* Parse line coding */
        line_dterate    = ep0_buf[0] | (ep0_buf[1] << 8) |
                          (ep0_buf[2] << 16) | (ep0_buf[3] << 24);
        line_charformat = ep0_buf[4];
        line_paritytype = ep0_buf[5];
        line_databits   = ep0_buf[6];
    }
    ep0_send_zlp();
}

/* =========================================================================
 * USB Interrupt Handlers
 * ========================================================================= */
static void handle_usb_reset(void) {
    usb_state = USB_STATE_DEFAULT;
    configured = 0;
    dwc2_w32(DOEPTSIZ0, 0);
    dwc2_w32(DOEPCTL0, 0);
    dwc2_flush_tx(0x10); /* Flush all TX FIFOs */
    dwc2_flush_rx();
    ep0_activate();
    uart_puts_local("usb: USB reset\n");
}

static void handle_enum_done(void) {
    uint32_t dsts = dwc2_r32(DSTS);
    int speed = (dsts & DSTS_ENUMSPD) >> 1;
    usb_state = USB_STATE_DEFAULT;
    ep0_activate();
    uart_puts_local(speed == 0 ? "usb: Connected HS\n" : "usb: Connected FS\n");
}

/* =========================================================================
 * Main Poll — called from the kernel's main loop
 * ========================================================================= */
void usb_poll(void) {
    uint32_t gint = dwc2_r32(GINTSTS);
    if (gint == 0) return;

    /* USB Reset */
    if (gint & GINT_USBRST) {
        dwc2_w32(GINTSTS, GINT_USBRST);
        handle_usb_reset();
        return;
    }

    /* Enumeration Done */
    if (gint & GINT_ENUMDONE) {
        dwc2_w32(GINTSTS, GINT_ENUMDONE);
        handle_enum_done();
        return;
    }

    /* RX FIFO Level — data/SETUP received */
    if (gint & GINT_RXFLVL) {
        dwc2_w32(GINTSTS, GINT_RXFLVL);
        /* Drain all entries from RX FIFO */
        while (1) {
            uint32_t sts = dwc2_r32(GRXSTSP);
            int pktsts = (sts >> 12) & 0xF;
            int bcnt   = (sts >> 4) & 0x7FF;
            int chnum  = sts & 0xF;
            (void)bcnt;

            if (pktsts == RXSTSP_PKTSTS_SETUP) {
                /* SETUP packet on EP0 */
                struct usb_setup setup;
                ep0_read_setup(&setup);
                handle_setup_packet(&setup);
            } else if (pktsts == RXSTSP_PKTSTS_OUT) {
                /* OUT data packet */
                if (chnum == 0) {
                    /* EP0 OUT data */
                    int words = (bcnt + 3) / 4;
                    for (int i = 0; i < words && ep0_buf_ptr < (int)sizeof(ep0_buf); i++) {
                        uint32_t w = dwc2_fifo_r32();
                        for (int j = 0; j < 4 && ep0_buf_ptr < (int)sizeof(ep0_buf); j++)
                            ep0_buf[ep0_buf_ptr++] = (w >> (j*8)) & 0xFF;
                    }
                } else if (chnum == 2) {
                    /* EP2 OUT — serial data from host */
                    int words = (bcnt + 3) / 4;
                    for (int i = 0; i < words; i++) {
                        uint32_t w = dwc2_fifo_r32();
                        for (int j = 0; j < 4 && bcnt > 0; j++) {
                            int next = (rx_tail + 1) % USB_BUF_SIZE;
                            if (next != rx_head) {
                                rx_buf[rx_tail] = (w >> (j*8)) & 0xFF;
                                rx_tail = next;
                            }
                            bcnt--;
                        }
                    }
                } else {
                    /* Drain unknown OUT data */
                    int words = (bcnt + 3) / 4;
                    for (int i = 0; i < words; i++) dwc2_fifo_r32();
                }
            } else if (pktsts == RXSTSP_PKTSTS_SETUPCOMP) {
                /* SETUP phase complete — no data, just status */
            } else {
                break;
            }
            /* Check if more RX data available */
            if (!(dwc2_r32(GINTSTS) & GINT_RXFLVL)) break;
        }
    }

    /* OUT EP Interrupt */
    if (gint & GINT_OEPINT) {
        dwc2_w32(GINTSTS, GINT_OEPINT);
        uint32_t daint = dwc2_r32(DAINT);
        if (daint & (1 << 16)) { /* EP0 OUT */
            uint32_t epint = dwc2_r32(DOEPINT0);
            dwc2_w32(DOEPINT0, epint);
            if (epint & EPINT_XFERCOMPL) {
                ep0_complete_out();
            }
        }
        if (daint & (1 << 18)) { /* EP2 OUT */
            uint32_t epint = dwc2_r32(DOEPINT2);
            dwc2_w32(DOEPINT2, epint);
            if (epint & EPINT_XFERCOMPL) {
                /* Re-arm EP2 OUT for next RX */
                dwc2_w32(DOEPTSIZ2, (1 << 19) | 64);
                dwc2_w32(DOEPCTL2, dwc2_r32(DOEPCTL2) | EPCTL_EPENA | EPCTL_CNAK);
            }
        }
    }

    /* IN EP Interrupt */
    if (gint & GINT_IEPINT) {
        dwc2_w32(GINTSTS, GINT_IEPINT);
        uint32_t daint = dwc2_r32(DAINT);
        if (daint & 1) { /* EP0 IN */
            uint32_t epint = dwc2_r32(DIEPINT0);
            dwc2_w32(DIEPINT0, epint);
            if (epint & EPINT_XFERCOMPL) {
                /* IN transfer complete — data sent */
            }
        }
        if (daint & (1 << 1)) { /* EP1 IN (notification) */
            dwc2_w32(DIEPINT1, dwc2_r32(DIEPINT1));
        }
        if (daint & (1 << 2)) { /* EP2 IN (TX data) */
            uint32_t epint = dwc2_r32(DIEPINT2);
            dwc2_w32(DIEPINT2, epint);
            /* TX data was sent, nothing else to do */
        }
    }
}

/* =========================================================================
 * USB Serial I/O
 * ========================================================================= */
int usb_is_configured(void) {
    return configured && usb_state >= USB_STATE_CONFIGURED;
}

int usb_putchar(char c) {
    int next = (tx_head + 1) % USB_BUF_SIZE;
    if (next == tx_tail) return -1; /* buffer full */
    tx_buf[tx_head] = (uint8_t)c;
    tx_head = next;
    return 0;
}

int usb_getchar(void) {
    if (rx_head == rx_tail) return -1;
    uint8_t c = rx_buf[rx_head];
    rx_head = (rx_head + 1) % USB_BUF_SIZE;
    return (int)c;
}

void usb_puts(const char *s) {
    while (*s) {
        if (usb_putchar(*s) < 0) break;
        s++;
    }
}

/* Flush TX buffer: send data via EP2 IN */
static void usb_tx_flush(void) {
    if (!usb_is_configured()) return;
    int avail = (tx_head - tx_tail + USB_BUF_SIZE) % USB_BUF_SIZE;
    if (avail == 0) return;
    int len = avail > 64 ? 64 : avail;
    /* Write data to EP2 IN FIFO */
    for (int i = 0; i < len; i++) {
        uint32_t w = 0;
        int remaining = len - i;
        for (int j = 0; j < 4 && remaining > 0; j++, i++, remaining--) {
            w |= (uint32_t)tx_buf[(tx_tail + i) % USB_BUF_SIZE] << (j*8);
        }
        i--;
        dwc2_fifo_w32(w);
    }
    /* Update tail */
    tx_tail = (tx_tail + len) % USB_BUF_SIZE;
    /* Trigger EP2 IN transfer */
    dwc2_w32(DIEPTSIZ2, (1 << 19) | len);
    dwc2_w32(DIEPCTL2, dwc2_r32(DIEPCTL2) | EPCTL_EPENA | EPCTL_CNAK);
}

/* =========================================================================
 * Boot Log
 * ========================================================================= */
static void bootlog_write(const char *msg) {
    uint32_t magic = *(volatile uint32_t *)(uintptr_t)BOOTLOG_BASE;
    if (magic != BOOTLOG_MAGIC) {
        *(volatile uint32_t *)(uintptr_t)BOOTLOG_BASE = BOOTLOG_MAGIC;
        *(volatile int *)(uintptr_t)(BOOTLOG_BASE + 4) = 0;
        *(volatile int *)(uintptr_t)(BOOTLOG_BASE + 8) = 0;
    }
    int count = *(volatile int *)(uintptr_t)(BOOTLOG_BASE + 4);
    int wpos  = *(volatile int *)(uintptr_t)(BOOTLOG_BASE + 8);
    int off = 16 + wpos * BOOTLOG_LEN;
    unsigned char *dst = (unsigned char *)(uintptr_t)(BOOTLOG_BASE + off);
    for (int i = 0; i < BOOTLOG_LEN - 1 && msg[i]; i++)
        dst[i] = (unsigned char)msg[i];
    dst[BOOTLOG_LEN - 1] = 0;
    wpos = (wpos + 1) % BOOTLOG_MAX;
    if (count < BOOTLOG_MAX) count++;
    *(volatile int *)(uintptr_t)(BOOTLOG_BASE + 4) = count;
    *(volatile int *)(uintptr_t)(BOOTLOG_BASE + 8) = wpos;
}

/* Send boot log over USB serial */
static void bootlog_drain(void) {
    if (!usb_is_configured() || !bootlog_ready) return;
    uint32_t magic = *(volatile uint32_t *)(uintptr_t)BOOTLOG_BASE;
    if (magic != BOOTLOG_MAGIC) return;
    int count = *(volatile int *)(uintptr_t)(BOOTLOG_BASE + 4);
    int wpos  = *(volatile int *)(uintptr_t)(BOOTLOG_BASE + 8);
    int rpos  = (count < BOOTLOG_MAX) ? 0 : wpos;
    for (int i = 0; i < count; i++) {
        int off = 16 + rpos * BOOTLOG_LEN;
        unsigned char *src = (unsigned char *)(uintptr_t)(BOOTLOG_BASE + off);
        for (int j = 0; j < BOOTLOG_LEN && src[j]; j++)
            usb_putchar((char)src[j]);
        usb_putchar('\n');
        rpos = (rpos + 1) % BOOTLOG_MAX;
    }
    bootlog_ready = 0;
    /* Clear log after drain */
    *(volatile int *)(uintptr_t)(BOOTLOG_BASE + 4) = 0;
    *(volatile int *)(uintptr_t)(BOOTLOG_BASE + 8) = 0;
}

/* =========================================================================
 * Initialization
 * ========================================================================= */
void usb_init(void) {
    uart_puts_local("usb: CDC ACM gadget starting...\n");

    /* 1. Reset core */
    dwc2_w32(GRSTCTL, GRSTCTL_CSFTRST);
    dwc2_busywait(50000);
    while (dwc2_r32(GRSTCTL) & GRSTCTL_CSFTRST);
    uart_puts_local("usb: core reset done\n");

    /* 2. Flush FIFOs */
    dwc2_flush_tx(0x10);
    dwc2_flush_rx();

    /* 3. Configure GUSBCFG */
    uint32_t gusb = dwc2_r32(GUSBCFG);
    gusb &= ~(GUSBCFG_PHYIF | GUSBCFG_TOUTCAL);
    gusb |= (4 << GUSBCFG_TOUTCAL_SHIFT); /* Turnaround time for FS */
    dwc2_w32(GUSBCFG, gusb);
    dwc2_busywait(1000);

    /* 4. Set device speed */
    dwc2_w32(DCFG, (dwc2_r32(DCFG) & ~3) | DCFG_DEVSPD_FS);

    /* 5. Configure FIFO sizes
     * Total FIFO depth for SG2002 DWC2 is assumed 1024 words (4KB)
     * RX FIFO: 128 words (512 bytes)
     * Non-periodic TX FIFO: 128 words, offset 128
     * Periodic TX FIFO 1 (EP1, interrupt): 64 words, offset 256
     */
    dwc2_w32(GRXFSIZ, 128);
    dwc2_w32(GNPTXFSIZ, (128 << 16) | 128);
    dwc2_w32(DIEPTXF1, (64 << 16) | 256);

    /* 6. Mask interrupts */
    dwc2_w32(GINTMSK, GINT_USBRST | GINT_ENUMDONE | GINT_RXFLVL |
             GINT_OEPINT | GINT_IEPINT | GINT_WKUP | GINT_OTGINT);

    /* 7. Enable EP0 */
    dwc2_w32(DIEPMSK, EPINT_XFERCOMPL | EPINT_TXFE | EPINT_EPDISBLD);
    dwc2_w32(DOEPMSK, EPINT_XFERCOMPL | EPINT_SETUP | EPINT_EPDISBLD);

    /* 8. Enable global interrupt */
    dwc2_w32(GAHBCFG, GAHBCFG_GLBLINTR);

    /* 9. EP0 activate */
    ep0_activate();

    /* 10. Enable EP0 IN/OUT interrupt in DAINTMSK */
    dwc2_w32(DAINTMSK, (1 << 0) | (1 << 16)); /* EP0 IN, EP0 OUT */

    /* 11. Soft connect */
    dwc2_w32(DCTL, dwc2_r32(DCTL) & ~DCTL_SFTDISCON);

    uart_puts_local("usb: DWC2 CDC ACM initialized (FS)\n");

    /* 12. Record boot log */
    bootlog_write("USB: CDC ACM initialized");
    bootlog_ready = 1;
}

/* Poll function for main loop — called from kernel shell */
void usb_poll_main(void) {
    usb_poll();
    if (usb_is_configured()) {
        usb_tx_flush();
        if (bootlog_ready) bootlog_drain();
    }
}
