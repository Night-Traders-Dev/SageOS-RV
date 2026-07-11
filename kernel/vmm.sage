## kernel/vmm.sage — Pure-Sage Virtual Memory Manager (SV39)
##
## RISC-V 64 SV39 three-level page table management.
## Ported from kernel/hw/vmm.c (90 lines of C).
##
## Architecture:
##   VPN[2] (bits 38:30) → Root table (L2)
##   VPN[1] (bits 29:21) → Middle table (L1)
##   VPN[0] (bits 20:12) → Leaf table (L0) → 4KB physical page
##
## All page table entries are 64-bit, stored in 4KB tables (512 entries each).
## Access via mem_read/mem_write builtins for direct physical address access.

let PAGE_SIZE = 4096
let PAGE_SHIFT = 12
let PTE_SIZE = 8
let PTE_PER_TABLE = 512

## SV39 address extraction
let VPN2_SHIFT = 30
let VPN1_SHIFT = 21
let VPN0_SHIFT = 12
let VPN_MASK   = 0x1FF

## PTE flags (bits 9:0)
let PTE_V = 1 << 0
let PTE_R = 1 << 1
let PTE_W = 1 << 2
let PTE_X = 1 << 3
let PTE_U = 1 << 4
let PTE_G = 1 << 5
let PTE_A = 1 << 6
let PTE_D = 1 << 7

## PTE_PPN_SHIFT = 10 (bits 10+ are physical page number)
let PTE_PPN_SHIFT = 10

## SATP mode (SV39 = 8)
let SATP_MODE_SV39 = 8

## --- Page allocator reference (from pmm.sage) ---
## pmm_alloc() returns physical address of a zeroed 4KB page

let root_table_phys = 0

## --- PTE Helpers ---

proc make_pte(ppn, flags):
    ## Build a 64-bit page table entry from PPN and flags
    return (ppn << PTE_PPN_SHIFT) | (flags & 0x3FF)

proc pte_ppn(pte):
    ## Extract physical page number from PTE
    return pte >> PTE_PPN_SHIFT

proc pte_is_valid(pte):
    return (pte & PTE_V) != 0

proc pte_is_leaf(pte):
    ## A leaf PTE has R, W, or X set
    return (pte & (PTE_R | PTE_W | PTE_X)) != 0

## --- Page Table Walker ---

proc table_read(table_phys, index):
    ## Read PTE at table_phys[index]
    return mem_read(table_phys + (index * PTE_SIZE), PTE_SIZE)

proc table_write(table_phys, index, pte):
    ## Write PTE to table_phys[index]
    mem_write(table_phys + (index * PTE_SIZE), pte, PTE_SIZE)

## --- VMM Init ---

proc vmm_init():
    root_table_phys = pmm_alloc()
    if root_table_phys == 0:
        return false

    ## Identity-map first 2MB of kernel space
    vmm_identity_map(0x80200000, 0x80400000, PTE_V | PTE_R | PTE_W | PTE_X | PTE_G)

    ## Map UART MMIO — identity map both QEMU virt (0x10000000)
    ## and LicheeRV SG2002 (0x04140000) so the correct one is
    ## accessible regardless of board. Unmapped pages are harmless.
    vmm_map_page(0x10000000, 0x10000000, PTE_V | PTE_R | PTE_W | PTE_G)
    vmm_map_page(0x04140000, 0x04140000, PTE_V | PTE_R | PTE_W | PTE_G)

    return true

## --- Map/Unmap ---

proc vmm_map_page(vaddr, paddr, flags):
    ## Extract VPN levels
    let vpn2 = (vaddr >> VPN2_SHIFT) & VPN_MASK
    let vpn1 = (vaddr >> VPN1_SHIFT) & VPN_MASK
    let vpn0 = (vaddr >> VPN0_SHIFT) & VPN_MASK

    ## Build PTE
    let ppn = paddr >> PAGE_SHIFT
    let pte = make_pte(ppn, flags)

    ## Walk from root table (L2)
    let l2_pte = table_read(root_table_phys, vpn2)
    if not pte_is_valid(l2_pte):
        ## Allocate L1 table
        let l1_phys = pmm_alloc()
        if l1_phys == 0:
            return false
        l2_pte = make_pte(l1_phys >> PAGE_SHIFT, PTE_V)
        table_write(root_table_phys, vpn2, l2_pte)

    let l1_phys = pte_ppn(l2_pte) << PAGE_SHIFT

    ## Walk L1 table
    let l1_pte = table_read(l1_phys, vpn1)
    if not pte_is_valid(l1_pte):
        ## Allocate L0 table
        let l0_phys = pmm_alloc()
        if l0_phys == 0:
            return false
        l1_pte = make_pte(l0_phys >> PAGE_SHIFT, PTE_V)
        table_write(l1_phys, vpn1, l1_pte)

    let l0_phys = pte_ppn(l1_pte) << PAGE_SHIFT

    ## Write leaf PTE at L0
    table_write(l0_phys, vpn0, pte)
    return true

proc vmm_unmap_page(vaddr):
    let vpn2 = (vaddr >> VPN2_SHIFT) & VPN_MASK
    let vpn1 = (vaddr >> VPN1_SHIFT) & VPN_MASK
    let vpn0 = (vaddr >> VPN0_SHIFT) & VPN_MASK

    let l2_pte = table_read(root_table_phys, vpn2)
    if not pte_is_valid(l2_pte):
        return

    let l1_phys = pte_ppn(l2_pte) << PAGE_SHIFT
    let l1_pte = table_read(l1_phys, vpn1)
    if not pte_is_valid(l1_pte):
        return

    let l0_phys = pte_ppn(l1_pte) << PAGE_SHIFT
    table_write(l0_phys, vpn0, 0)

proc vmm_identity_map(vaddr_start, vaddr_end, flags):
    let addr = vaddr_start
    while addr < vaddr_end:
        vmm_map_page(addr, addr, flags)
        addr = addr + PAGE_SIZE

proc vmm_translate(vaddr):
    let vpn2 = (vaddr >> VPN2_SHIFT) & VPN_MASK
    let vpn1 = (vaddr >> VPN1_SHIFT) & VPN_MASK
    let vpn0 = (vaddr >> VPN0_SHIFT) & VPN_MASK

    let offset = vaddr & (PAGE_SIZE - 1)

    let l2_pte = table_read(root_table_phys, vpn2)
    if not pte_is_valid(l2_pte):
        return 0

    let l1_phys = pte_ppn(l2_pte) << PAGE_SHIFT
    let l1_pte = table_read(l1_phys, vpn1)
    if not pte_is_valid(l1_pte):
        return 0

    let l0_phys = pte_ppn(l1_pte) << PAGE_SHIFT
    let l0_pte = table_read(l0_phys, vpn0)
    if not pte_is_valid(l0_pte):
        return 0

    return (pte_ppn(l0_pte) << PAGE_SHIFT) | offset
