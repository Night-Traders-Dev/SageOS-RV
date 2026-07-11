## kernel/hw/dtb.sage — Pure-Sage Device Tree Blob (FDT) Parser
##
## Ported from kernel/hw/dtb.c (188 lines of C).
## Parses the Flattened Device Tree passed by OpenSBI.
## No hardware dependencies — pure memory reads via mem_read builtin.
##
## FDT format: devicetree-specification v0.4
##
## Usage:
##   let info = dtb_parse(dtb_addr)
##   info.mem_base, info.mem_size, info.uart_base, info.plic_base, etc.

## --- FDT Token Constants ---

let FDT_MAGIC      = 0xD00DFEED
let FDT_BEGIN_NODE = 0x00000001
let FDT_END_NODE   = 0x00000002
let FDT_PROP       = 0x00000003
let FDT_NOP        = 0x00000004
let FDT_END        = 0x00000009

## --- Big-Endian Helpers ---

proc be32_le(word):
    ## Convert big-endian 32-bit word to host (little-endian) byte order
    let b0 = word & 0xFF
    let b1 = (word >> 8) & 0xFF
    let b2 = (word >> 16) & 0xFF
    let b3 = (word >> 24) & 0xFF
    return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3

proc align4(val):
    return (val + 3) & ~3

proc dtb_read32(base, offset):
    ## Read a 32-bit big-endian word from the DTB buffer
    let word = mem_read(base + offset, 4)
    return be32_le(word)

## --- String Helpers ---

proc str_match_at(base, offset, target, target_len):
    ## Compare string at base+offset with target (length target_len)
    let i = 0
    while i < target_len:
        let c = mem_read(base + offset + i, 1)
        let tc = target[i] & 0xFF
        if c != tc:
            return false
        i = i + 1
    return true

proc node_name_matches(base, name_offset, target):
    ## Check if FDT node name matches target (stops at '@' or '\0')
    let i = 0
    while i < len(target):
        let c = mem_read(base + name_offset + i, 1)
        let tc = target[i] & 0xFF
        if c != tc:
            return false
        i = i + 1
    let next = mem_read(base + name_offset + i, 1)
    if next == 0 or next == 64:   ## '\0' or '@'
        return true
    return false

proc str_at_equals(base, offset, target):
    ## Check if string at base+offset equals target
    let i = 0
    while i < len(target):
        let c = mem_read(base + offset + i, 1)
        if c != (target[i] & 0xFF):
            return false
        i = i + 1
    let term = mem_read(base + offset + i, 1)
    return term == 0

proc compatible_matches(base, val_offset, val_len, match):
    ## Check if compatible property contains match string
    let pos = 0
    while pos < val_len:
        ## Compare match string at current position
        let m = 0
        let ok = true
        while m < len(match):
            let c = mem_read(base + val_offset + pos + m, 1)
            if c != (match[m] & 0xFF):
                ok = false
            m = m + 1
        if ok:
            let next = mem_read(base + val_offset + pos + m, 1)
            if next == 0 or next == 44:   ## '\0' or ','
                return true
        ## Skip to next null-terminated string
        while pos < val_len:
            if mem_read(base + val_offset + pos, 1) == 0:
                pos = pos + 1
            else:
                pos = pos + 1
    return false

## --- DTB Parser ---

proc dtb_parse(dtb_addr):
    let info = {
        mem_base:   0,
        mem_size:   0,
        uart_base:  0,
        plic_base:  0,
        timer_freq: 0,
        cpu_count:  0,
        valid:      0
    }

    ## Read FDT header (6×4 bytes at offset 0)
    let magic   = dtb_read32(dtb_addr, 0)
    let totalsz = dtb_read32(dtb_addr, 4)
    let off_dt_struct  = dtb_read32(dtb_addr, 8)
    let off_dt_strings = dtb_read32(dtb_addr, 12)
    let version = dtb_read32(dtb_addr, 20)

    if magic != FDT_MAGIC:
        return info
    if version < 16:
        return info

    let depth = 0
    let in_memory = false
    let in_cpus   = false
    let cur_is_uart = false
    let cur_is_plic = false
    let addr_cells = 2
    let size_cells = 1

    let sp = off_dt_struct   ## Offset into struct block
    let strblock = off_dt_strings   ## Offset to strings block

    while sp < totalsz:
        let token = dtb_read32(dtb_addr, sp)
        sp = sp + 4

        if token == FDT_BEGIN_NODE:
            let name_off = sp
            ## Skip name (null-terminated, aligned to 4 bytes)
            let nlen = 0
            while mem_read(dtb_addr + name_off + nlen, 1) != 0:
                nlen = nlen + 1
            sp = sp + align4(nlen + 1)

            cur_is_uart = false
            cur_is_plic = false

            if depth == 1:
                if node_name_matches(dtb_addr, name_off, "memory"):
                    in_memory = true
                elif node_name_matches(dtb_addr, name_off, "cpus"):
                    in_cpus = true
            depth = depth + 1

        elif token == FDT_END_NODE:
            depth = depth - 1
            if depth == 1:
                in_memory = false
                in_cpus = false
            cur_is_uart = false
            cur_is_plic = false

        elif token == FDT_PROP:
            let len     = dtb_read32(dtb_addr, sp)
            let nameoff = dtb_read32(dtb_addr, sp + 4)
            sp = sp + 8
            let val_off = sp
            sp = sp + align4(len)

            ## Check compatible property
            if str_at_equals(dtb_addr, strblock + nameoff, "compatible"):
                cur_is_uart = compatible_matches(dtb_addr, val_off, len, "ns16550a") or
                              compatible_matches(dtb_addr, val_off, len, "ns16550")
                cur_is_plic = compatible_matches(dtb_addr, val_off, len, "riscv,plic0")

            ## Parse reg property (address + size)
            if str_at_equals(dtb_addr, strblock + nameoff, "reg") and len >= 8:
                let ac = addr_cells
                let sc = size_cells
                if depth != 1:
                    ac = 2
                    sc = 1

                let addr = 0
                let size = 0
                let rp = val_off

                if ac >= 2:
                    let hi = dtb_read32(dtb_addr, rp)
                    let lo = dtb_read32(dtb_addr, rp + 4)
                    addr = (hi << 32) | lo
                    rp = rp + 8
                else:
                    addr = dtb_read32(dtb_addr, rp)
                    rp = rp + 4

                if sc >= 2:
                    let shi = dtb_read32(dtb_addr, rp)
                    let slo = dtb_read32(dtb_addr, rp + 4)
                    size = (shi << 32) | slo
                else:
                    size = dtb_read32(dtb_addr, rp)

                if cur_is_uart and info.uart_base == 0:
                    info.uart_base = addr
                if cur_is_plic and info.plic_base == 0:
                    info.plic_base = addr
                if in_memory:
                    info.mem_base = addr
                    info.mem_size = size

            ## Root node: #address-cells, #size-cells
            if depth == 1:
                if str_at_equals(dtb_addr, strblock + nameoff, "#address-cells") and len >= 4:
                    addr_cells = dtb_read32(dtb_addr, val_off)
                if str_at_equals(dtb_addr, strblock + nameoff, "#size-cells") and len >= 4:
                    size_cells = dtb_read32(dtb_addr, val_off)

            ## CPU node: timebase-frequency, riscv,isa
            if in_cpus and str_at_equals(dtb_addr, strblock + nameoff, "timebase-frequency") and len >= 4:
                info.timer_freq = dtb_read32(dtb_addr, val_off)
            if in_cpus and str_at_equals(dtb_addr, strblock + nameoff, "riscv,isa"):
                info.cpu_count = info.cpu_count + 1

        elif token == FDT_END:
            sp = totalsz   ## Exit loop

    ## Apply fallback defaults (board-aware)
    if info.mem_size == 0:
        info.mem_size = 128 * 1024 * 1024
    if info.timer_freq == 0:
        info.timer_freq = 10000000
    if info.uart_base == 0:
        info.uart_base = 0x10000000
    if info.plic_base == 0:
        info.plic_base = 0x0C000000
    ## The MetalRV64 VM sets net_backend/etc. before running commands;
    ## dtb overrides for LicheeRV are set by the board BSP at runtime

    info.valid = 1
    return info
