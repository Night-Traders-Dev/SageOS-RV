#ifndef DTB_H
#define DTB_H

#include <stdint.h>

typedef struct {
    uint64_t mem_base;
    uint64_t mem_size;
    uint64_t uart_base;
    uint64_t plic_base;
    uint64_t timer_freq;
    int      cpu_count;
    int      valid;
} dtb_info_t;

int dtb_parse(uint64_t dtb_addr, dtb_info_t *info);
int dtb_verify(uint64_t dtb_addr);

enum {
    FDT_MAGIC        = 0xD00DFEED,
    FDT_BEGIN_NODE   = 0x00000001,
    FDT_END_NODE     = 0x00000002,
    FDT_PROP         = 0x00000003,
    FDT_NOP          = 0x00000004,
    FDT_END          = 0x00000009,
};

#endif
