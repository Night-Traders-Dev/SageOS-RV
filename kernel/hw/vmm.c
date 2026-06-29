#include "vmm.h"
#include "sbi.h"

/* PMM alloc/free — forward declared, implemented in fallback_kernel.c */
extern uint64_t pmm_alloc(void);

static uint64_t root_table_phys = 0;

static uint64_t *table_from_phys(uint64_t phys) {
    return (uint64_t *)(uint64_t)phys;
}

static uint64_t make_pte(uint64_t ppn, uint64_t flags) {
    return (ppn << PTE_PPN_SHIFT) | flags;
}

static uint64_t pte_ppn(uint64_t pte) {
    return (pte >> PTE_PPN_SHIFT);
}

int vmm_init(void) {
    root_table_phys = pmm_alloc();
    if (root_table_phys == 0)
        return -1;

    uint64_t *root = table_from_phys(root_table_phys);
    for (int i = 0; i < 512; i++)
        root[i] = 0;

    return 0;
}

int vmm_map_page(uint64_t vaddr, uint64_t paddr, uint64_t flags) {
    if (root_table_phys == 0)
        return -1;

    uint64_t vpn2 = (vaddr >> 30) & 0x1FF;
    uint64_t vpn1 = (vaddr >> 21) & 0x1FF;
    uint64_t vpn0 = (vaddr >> 12) & 0x1FF;
    uint64_t ppn  = paddr >> PAGE_SHIFT;

    uint64_t *table = table_from_phys(root_table_phys);

    /* Level 2 -> Level 1 */
    if (!(table[vpn2] & PTE_V)) {
        uint64_t l1_phys = pmm_alloc();
        if (l1_phys == 0) return -1;
        uint64_t *l1 = table_from_phys(l1_phys);
        for (int i = 0; i < 512; i++) l1[i] = 0;
        table[vpn2] = make_pte(l1_phys >> PAGE_SHIFT, PTE_V);
    }
    table = table_from_phys(pte_ppn(table[vpn2]) << PAGE_SHIFT);

    /* Level 1 -> Level 0 */
    if (!(table[vpn1] & PTE_V)) {
        uint64_t l0_phys = pmm_alloc();
        if (l0_phys == 0) return -1;
        uint64_t *l0 = table_from_phys(l0_phys);
        for (int i = 0; i < 512; i++) l0[i] = 0;
        table[vpn1] = make_pte(l0_phys >> PAGE_SHIFT, PTE_V);
    }
    table = table_from_phys(pte_ppn(table[vpn1]) << PAGE_SHIFT);

    /* Level 0 -> leaf page */
    table[vpn0] = make_pte(ppn, PTE_V | flags);
    __asm__ volatile("sfence.vma zero, zero" ::: "memory");

    return 0;
}

void vmm_identity_map(uint64_t start, uint64_t end, uint64_t flags) {
    for (uint64_t addr = start; addr < end; addr += PAGE_SIZE)
        vmm_map_page(addr, addr, flags);
}

int vmm_activate(void) {
    if (root_table_phys == 0)
        return -1;

    uint64_t ppn = root_table_phys >> PAGE_SHIFT;
    uint64_t satp_val = (SATP_MODE_SV39 << 60) |
                        (SATP_ASID_DEFAULT << 44) |
                        ppn;

    __asm__ volatile("sfence.vma\n\t"
                     "csrw satp, %0\n\t"
                     "sfence.vma"
                     :: "r"(satp_val));

    return 0;
}
