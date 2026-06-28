#include "dtb.h"

static inline uint32_t be32(const uint32_t *p) {
    const uint8_t *b = (const uint8_t *)p;
    return ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) |
           ((uint32_t)b[2] <<  8) |  (uint32_t)b[3];
}

static inline uint32_t align4(uint32_t val) {
    return (val + 3) & ~3;
}

static int node_name_is(const uint8_t *name, const char *target) {
    while (*target) {
        if (*name++ != (uint8_t)*target++) return 0;
    }
    return *name == '\0' || *name == '@';
}

static int prop_name_is(const char *strblock, uint32_t off, const char *name) {
    const char *s = strblock + off;
    while (*name) {
        if (*s++ != *name++) return 0;
    }
    return *s == '\0';
}

int dtb_verify(uint64_t dtb_addr) {
    const uint32_t *hdr = (const uint32_t *)(uint64_t)dtb_addr;
    if (be32(&hdr[0]) != FDT_MAGIC) return -1;
    if (be32(&hdr[5]) < 16) return -1;
    return 0;
}

int dtb_parse(uint64_t dtb_addr, dtb_info_t *info) {
    const uint8_t *base = (const uint8_t *)(uint64_t)dtb_addr;
    const uint32_t *hdr = (const uint32_t *)base;

    info->mem_base   = 0;
    info->mem_size   = 0;
    info->uart_base  = 0x10000000;
    info->plic_base  = 0x0C000000;
    info->timer_freq = 0;
    info->cpu_count  = 0;
    info->valid      = 0;

    if (be32(&hdr[0]) != FDT_MAGIC) return -1;

    uint32_t totalsize      = be32(&hdr[1]);
    uint32_t off_dt_struct  = be32(&hdr[2]);
    uint32_t off_dt_strings = be32(&hdr[3]);
    uint32_t version        = be32(&hdr[5]);

    if (version < 16) return -1;

    const uint32_t *sp = (const uint32_t *)(base + off_dt_struct);
    const char *strblock   = (const char *)(base + off_dt_strings);
    const uint8_t *end     = base + totalsize;

    int depth = 0, in_memory = 0, in_cpus = 0;

    while ((const uint8_t *)sp < end) {
        uint32_t token = be32(sp++);

        switch (token) {
        case FDT_BEGIN_NODE: {
            const uint8_t *name = (const uint8_t *)sp;
            uint32_t nlen = 0;
            while (name[nlen]) nlen++;
            sp += align4(nlen + 1) / 4;

            if (depth == 1) {
                if (node_name_is(name, "memory")) in_memory = 1;
                else if (node_name_is(name, "cpus")) in_cpus = 1;
            }
            depth++;
            break;
        }

        case FDT_END_NODE:
            depth--;
            if (depth == 1) { in_memory = 0; in_cpus = 0; }
            break;

        case FDT_PROP: {
            uint32_t len     = be32(sp++);
            uint32_t nameoff = be32(sp++);
            const uint8_t *val = (const uint8_t *)sp;
            sp += align4(len) / 4;

            if (in_memory && prop_name_is(strblock, nameoff, "reg")) {
                if (len >= 16) {
                    uint64_t hi_a = be32((const uint32_t *)val);
                    uint64_t lo_a = be32((const uint32_t *)val + 1);
                    uint64_t hi_s = be32((const uint32_t *)val + 2);
                    uint64_t lo_s = be32((const uint32_t *)val + 3);
                    info->mem_base = (hi_a << 32) | lo_a;
                    info->mem_size = (hi_s << 32) | lo_s;
                } else if (len >= 8) {
                    info->mem_base = be32((const uint32_t *)val);
                    info->mem_size = be32((const uint32_t *)val + 1);
                }
            }

            if (in_cpus && prop_name_is(strblock, nameoff, "timebase-frequency")) {
                if (len >= 4)
                    info->timer_freq = be32((const uint32_t *)val);
            }

            break;
        }

        case FDT_END:
            goto done;

        default:
            break;
        }
    }

done:
    if (info->mem_size == 0) {
        info->mem_base = 0x80200000;
        info->mem_size = 128UL * 1024 * 1024;
    }
    if (info->timer_freq == 0)
        info->timer_freq = 10000000;

    info->valid = 1;
    return 0;
}
