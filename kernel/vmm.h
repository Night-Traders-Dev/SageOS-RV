#ifndef VMM_H
#define VMM_H

#include <stdint.h>

#define PAGE_SIZE   4096UL
#define PAGE_SHIFT  12

/* SV39 page table flags */
#define PTE_V  (1UL << 0)
#define PTE_R  (1UL << 1)
#define PTE_W  (1UL << 2)
#define PTE_X  (1UL << 3)
#define PTE_U  (1UL << 4)
#define PTE_G  (1UL << 5)
#define PTE_A  (1UL << 6)
#define PTE_D  (1UL << 7)

#define PTE_PPN_SHIFT 10
#define SATP_MODE_SV39 8UL
#define SATP_ASID_DEFAULT 0UL

int  vmm_init(void);
int  vmm_map_page(uint64_t vaddr, uint64_t paddr, uint64_t flags);
int  vmm_activate(void);
void vmm_identity_map(uint64_t start, uint64_t end, uint64_t flags);

#endif
