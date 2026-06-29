OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY {
    RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 254M
}

SECTIONS {

    .text : {
        KEEP(*(.text.boot))
        *(.text .text.*)
    } > RAM

    .rodata : {
        *(.rodata .rodata.*)
    } > RAM

    .sgvm_shell : {
        _shell_sgvm_start = .;
        KEEP(*(.sgvm_shell))
        _shell_sgvm_end = .;
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
    _image_end  = .;

    /DISCARD/ : {
        *(.note*)
        *(.comment)
        *(.eh_frame*)
    }
}

_heap_end  = 0x8FE00000;
_stack_top = 0x8FE00000;
