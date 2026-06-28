/*
 * linker.ld — SageOS-RV linker script
 *
 * Memory map (QEMU virt, OpenSBI loads kernel at 0x80200000):
 *
 *   0x80200000  .text       — kernel code
 *   ...         .rodata     — read-only data (strings, tables)
 *   ...         .sgvm_shell — embedded shell.sgvm bytecode blob
 *   ...         .data       — initialised read-write data
 *   ...         .bss        — zero-initialised data
 *   ...         _heap_start — start of physical page allocator arena
 *   0x88000000  _heap_end   — end of usable RAM (128 MB from 0x80000000)
 *
 * The .sgvm_shell section is populated by objcopy in sagemake.
 * _shell_sgvm_start / _shell_sgvm_end are exposed as extern symbols
 * so kernel/kmain.sage can locate the bytecode at runtime.
 * When shell.sgvm was not embedded both symbols point to the same
 * address (_shell_sgvm_start == _shell_sgvm_end, size == 0).
 */

OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY {
    RAM (rwx) : ORIGIN = 0x80200000, LENGTH = 126M
}

SECTIONS {

    /* ------------------------------------------------------------------ */
    /* Kernel code                                                         */
    /* ------------------------------------------------------------------ */
    .text : {
        KEEP(*(.text.boot))
        *(.text .text.*)
    } > RAM

    /* ------------------------------------------------------------------ */
    /* Read-only data                                                      */
    /* ------------------------------------------------------------------ */
    .rodata : {
        *(.rodata .rodata.*)
    } > RAM

    /* ------------------------------------------------------------------ */
    /* Embedded shell bytecode                                            */
    /*                                                                     */
    /* objcopy (embed_shell_sgvm in sagemake) produces shell_sgvm.o with  */
    /* the blob in a section named .sgvm_shell.  We KEEP it so the linker */
    /* does not discard it as unused, and expose start/end symbols.       */
    /* ------------------------------------------------------------------ */
    .sgvm_shell : {
        _shell_sgvm_start = .;
        KEEP(*(.sgvm_shell))
        _shell_sgvm_end = .;
    } > RAM

    /* ------------------------------------------------------------------ */
    /* Initialised data                                                    */
    /* ------------------------------------------------------------------ */
    .data : {
        *(.data .data.*)
        *(.sdata .sdata.*)
    } > RAM

    /* ------------------------------------------------------------------ */
    /* Zero-initialised data                                              */
    /* ------------------------------------------------------------------ */
    .bss : {
        _bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        _bss_end = .;
    } > RAM

    /* ------------------------------------------------------------------ */
    /* Heap / PMM arena                                                    */
    /* ------------------------------------------------------------------ */
    . = ALIGN(4096);
    _heap_start = .;
    _image_end  = .;

    _heap_end   = ORIGIN(RAM) + LENGTH(RAM);
    _stack_top  = _heap_end;

    /DISCARD/ {
        *(.note*)
        *(.comment)
        *(.eh_frame*)
    }
}
