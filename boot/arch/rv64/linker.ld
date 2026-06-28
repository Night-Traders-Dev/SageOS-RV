## boot/arch/rv64/linker.ld — Linker script for SageOS-RV on RISC-V 64
## Target: QEMU virt machine (OpenSBI S-mode entry at 0x80200000)
##        LicheeRV Nano (SG2002, same entry point via OpenSBI)

OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
    RAM (rwxa) : ORIGIN = 0x80200000, LENGTH = 128M
}

SECTIONS
{
    . = 0x80200000;

    .text : {
        KEEP(*(.text.boot))
        *(.text .text.*)
    } > RAM

    .rodata : {
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
    } > RAM

    .data : {
        *(.data .data.*)
        *(.sdata .sdata.*)
    } > RAM

    .bss : {
        _bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        _bss_end = .;
    } > RAM

    . = ALIGN(4096);
    _heap_start = .;
    . = . + 0x400000;
    _heap_end = .;

    _stack_bottom = .;
    . = . + 0x4000;
    _stack_top = .;

    _image_end = .;
}
