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

static int compatible_is(const uint8_t *val, uint32_t len, const char *match) {
    /* Match first null-terminated string in the compatible property */
    const char *s = (const char *)val;
    uint32_t pos = 0;
    while (pos < len) {
        const char *start = &s[pos];
        const char *m = match;
        while (*m && (uint8_t)*m == (uint8_t)*start) { m++; start++; }
        if (*m == '\0' && (*start == '\0' || *start == ','))
            return 1;
        while (pos < len && s[pos]) pos++;
        pos++; /* skip null */
    }
    return 0;
}

int dtb_parse(uint64_t dtb_addr, dtb_info_t *info) {
    const uint8_t *base = (const uint8_t *)(uint64_t)dtb_addr;
    const uint32_t *hdr = (const uint32_t *)base;

    info->mem_base   = 0;
    info->mem_size   = 0;
    info->uart_base  = 0;
    info->plic_base  = 0;
    info->timer_freq = 0;
    info->cpu_count  = 0;
    info->valid      = 0;

    if (be32(&hdr[0]) != FDT_MAGIC) return -1;

    uint32_t totalsize      = be32(&hdr[1]);
    uint32_t off_dt_struct  = be32(&hdr[2]);
    uint32_t off_dt_strings = be32(&hdr[3]);
    uint32_t version        = be32(&hdr[5]);

    if (version < 16) return -1;
    if (totalsize < 40) return -1;
    if (off_dt_struct >= totalsize || off_dt_strings >= totalsize) return -1;

    const uint32_t *sp = (const uint32_t *)(base + off_dt_struct);
    const char *strblock   = (const char *)(base + off_dt_strings);
    const uint8_t *struct_end = base + totalsize;
    const uint8_t *strings_end = base + totalsize;

    int depth = 0, in_memory = 0, in_cpus = 0;
    int cur_is_uart = 0, cur_is_plic = 0;
    int addr_cells = 2, size_cells = 1;

    const uint8_t *end = struct_end;
    while ((const uint8_t *)sp < end) {
        uint32_t token = be32(sp++);

        switch (token) {
        case FDT_BEGIN_NODE: {
            const uint8_t *name = (const uint8_t *)sp;
            uint32_t nlen = 0;
            while (name[nlen]) nlen++;
            sp += align4(nlen + 1) / 4;

            cur_is_uart = 0;
            cur_is_plic = 0;

            if (depth == 1) {
                if (node_name_is(name, "memory"))
                    in_memory = 1;
                else if (node_name_is(name, "cpus"))
                    in_cpus = 1;
            }
            depth++;
            break;
        }

        case FDT_END_NODE:
            depth--;
            if (depth == 1) { in_memory = 0; in_cpus = 0; }
            cur_is_uart = 0;
            cur_is_plic = 0;
            break;

        case FDT_PROP: {
            if ((const uint8_t *)(sp + 2) > end) goto done;
            uint32_t len     = be32(sp++);
            uint32_t nameoff = be32(sp++);
            const uint8_t *val = (const uint8_t *)sp;
            if (val + len > end) goto done;
            sp += align4(len) / 4;

            if (off_dt_strings + nameoff >= totalsize) break;
            if (prop_name_is(strblock, nameoff, "compatible")) {
                cur_is_uart = compatible_is(val, len, "ns16550a") ||
                              compatible_is(val, len, "ns16550");
                cur_is_plic = compatible_is(val, len, "riscv,plic0");
            }

            if (prop_name_is(strblock, nameoff, "reg") && len >= 8) {
                int ac = (depth == 1) ? addr_cells : 2;
                int sc = (depth == 1) ? size_cells : 1;
                const uint32_t *rp = (const uint32_t *)val;
                uint64_t addr = 0, size = 0;
                if (ac >= 2) {
                    addr = (uint64_t)be32(rp) << 32 | be32(rp + 1);
                    rp += 2;
                } else {
                    addr = be32(rp);
                    rp += 1;
                }
                if (sc >= 2) {
                    size = (uint64_t)be32(rp) << 32 | be32(rp + 1);
                } else {
                    size = be32(rp);
                }

                if (cur_is_uart && info->uart_base == 0)
                    info->uart_base = addr;
                if (cur_is_plic && info->plic_base == 0)
                    info->plic_base = addr;
                if (in_memory) {
                    info->mem_base = addr;
                    info->mem_size = size;
                }
            }

            if (depth == 1) {
                if (prop_name_is(strblock, nameoff, "#address-cells") && len >= 4)
                    addr_cells = be32((const uint32_t *)val);
                if (prop_name_is(strblock, nameoff, "#size-cells") && len >= 4)
                    size_cells = be32((const uint32_t *)val);
            }

            if (in_cpus && prop_name_is(strblock, nameoff, "timebase-frequency") && len >= 4)
                info->timer_freq = be32((const uint32_t *)val);

            if (in_cpus && prop_name_is(strblock, nameoff, "riscv,isa"))
                info->cpu_count++;

            break;
        }

        case FDT_END:
            goto done;

        default:
            break;
        }
    }

done:
#ifdef CONFIG_BOARD_LICHEERV_NANO
    if (info->mem_size == 0) {
        info->mem_base = 0x80200000;
        info->mem_size = 256UL * 1024 * 1024;
    }
    if (info->timer_freq == 0)
        info->timer_freq = 25000000;
    if (info->uart_base == 0)
        info->uart_base = 0x04140000;
    if (info->plic_base == 0)
        info->plic_base = 0x0C000000;
#else
    if (info->mem_size == 0) {
        info->mem_base = 0x80200000;
        info->mem_size = 128UL * 1024 * 1024;
    }
    if (info->timer_freq == 0)
        info->timer_freq = 10000000;
    if (info->uart_base == 0)
        info->uart_base = 0x10000000;
    if (info->plic_base == 0)
        info->plic_base = 0x0C000000;
#endif

    info->valid = 1;
    return 0;
}
