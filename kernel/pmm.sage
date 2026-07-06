## kernel/pmm.sage — Physical Memory Manager
##
## Bitmap-based physical page allocator for RISC-V 64.
## One bit per 4KB page. Memory starts at MEM_BASE.

let PAGE_SIZE = 4096
let PAGE_SHIFT = 12

## Bitmap stored as array of 64-bit words
let bitmap = []
let bitmap_words = 0
let total_pages = 0
let free_pages = 0
let mem_base = 0

## Initialize PMM with memory region
proc pmm_init(base, size):
    mem_base = base
    total_pages = size / PAGE_SIZE
    free_pages = total_pages
    bitmap_words = (total_pages + 63) / 64

    ## Initialize bitmap (all free = all 1s)
    let i = 0
    while i < bitmap_words:
        push(bitmap, 0xFFFFFFFFFFFFFFFF)
        i = i + 1

    ## Mark first few pages as used (kernel image)
    let kernel_pages = 256
    i = 0
    while i < kernel_pages:
        pmm_mark_used(i)
        i = i + 1

## Mark a page as used (clear bit)
proc pmm_mark_used(page_idx):
    let word = page_idx / 64
    let bit = page_idx % 64
    let mask = 1 << bit
    bitmap[word] = bitmap[word] & (~mask)
    free_pages = free_pages - 1

## Mark a page as free (set bit)
proc pmm_mark_free(page_idx):
    let word = page_idx / 64
    let bit = page_idx % 64
    let mask = 1 << bit
    bitmap[word] = bitmap[word] | mask
    free_pages = free_pages + 1

## Allocate a single 4KB page
## Returns physical address or 0 on failure
proc pmm_alloc():
    if free_pages == 0:
        return 0

    let word = 0
    while word < bitmap_words:
        if bitmap[word] != 0:
            ## Find first set bit
            let bit = 0
            while bit < 64:
                let mask = 1 << bit
                if (bitmap[word] & mask) != 0:
                    let page_idx = word * 64 + bit
                    if page_idx < total_pages:
                        pmm_mark_used(page_idx)
                        return mem_base + page_idx * PAGE_SIZE
                    return 0
                bit = bit + 1
        word = word + 1

    return 0

## Free a physical page
proc pmm_free(addr):
    if addr < mem_base or (addr % PAGE_SIZE) != 0:
        return
    let page_idx = (addr - mem_base) / PAGE_SIZE
    if page_idx >= 0 and page_idx < total_pages:
        pmm_mark_free(page_idx)

## Allocate contiguous pages
## Returns base physical address or 0 on failure
proc pmm_alloc_pages(count):
    if count == 1:
        return pmm_alloc()

    ## Simple linear search for contiguous free pages
    let start = 0
    while start < total_pages:
        let found = true
        let j = 0
        while j < count:
            let page_idx = start + j
            let word = page_idx / 64
            let bit = page_idx % 64
            let mask = 1 << bit
            if word >= bitmap_words or (bitmap[word] & mask) == 0:
                found = false
                j = count
            j = j + 1

        if found:
            j = 0
            while j < count:
                pmm_mark_used(start + j)
                j = j + 1
            return mem_base + start * PAGE_SIZE

        start = start + 1

    return 0

## Get statistics
proc pmm_stats():
    let stats = {}
    stats["total_pages"] = total_pages
    stats["free_pages"] = free_pages
    stats["used_pages"] = total_pages - free_pages
    stats["total_kb"] = total_pages * 4
    stats["free_kb"] = free_pages * 4
    return stats
