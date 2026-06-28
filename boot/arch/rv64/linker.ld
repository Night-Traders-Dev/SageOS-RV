## boot/arch/rv64/linker.ld — Linker script for SageOS-RV on RISC-V 64
## Target: QEMU virt machine (OpenSBI S-mode entry at 0x80200000)
##        LicheeRV Nano (SG2002, same entry point via OpenSBI)

OUTPUT_ARCH("riscv")
ENTRY(_start)

PHDRS
{
    text   PT_LOAD FLAGS(5);   /* R+X */
    rodata PT_LOAD FLAGS(4);   /* R   */
    data   PT_LOAD FLAGS(6);   /* R+W */
    bss    PT_LOAD FLAGS(6);   /* R+W */
}

SECTIONS
{
    . = 0x80200000;

    .text ALIGN(4096) : {
        KEEP(*(.text.boot))
        *(.text .text.*)
    } :text

    .rodata ALIGN(4096) : {
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
    } :rodata

    .data ALIGN(4096) : {
        *(.data .data.*)
        *(.sdata .sdata.*)
    } :data

    .bss ALIGN(4096) : {
        _bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        _bss_end = .;
    } :bss

    . = ALIGN(4096);
    _heap_start = .;
    . = . + 0x400000;
    _heap_end = .;

    _stack_bottom = .;
    . = . + 0x4000;
    _stack_top = .;

    _image_end = .;
}
