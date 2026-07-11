/* kernel/drivers/usb_cdc_acm.h — USB CDC ACM Gadget Interface */

#ifndef USB_CDC_ACM_H
#define USB_CDC_ACM_H

#include <stdint.h>

void usb_init(void);
void usb_poll(void);
void usb_poll_main(void);
int  usb_putchar(char c);
int  usb_getchar(void);
int  usb_is_configured(void);
void usb_puts(const char *s);

#endif
