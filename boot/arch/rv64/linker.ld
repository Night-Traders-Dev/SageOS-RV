/*
 * linker.ld - SageOS-RV linker script
 *
 * Memory map (QEMU virt, OpenSBI loads kernel at 0x80200000):
 *
 *   0x80200000  .text        - kernel code
 *   ...         .rodata      - read-only data
 *   ...         .sgvm_shell  - embedded shell.sgvm bytecode blob
 *   ...         .data        - initialised read-write data
 *   ...         .bss         - zero-initialised data
 *   ...         _heap_start  - PMM arena start (page-aligned)
 *   0x87E00000  _heap_end    - PMM arena end  (126M - 2M guard)
 *   0x87E00000  _stack_top   - initial stack top
 */

OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY {
    RAM (rwx) : ORIGIN = 0x80200000, LENGTH = 126M
}

SECTIONS {

    /* Kernel code */
    .text : {
        KEEP(*(.text.boot))
        *(.text .text.*)
    } > RAM

    /* Read-only data */
    .rodata : {
        *(.rodata .rodata.*)
    } > RAM

    /*
     * Embedded shell bytecode blob.
     * Populated by objcopy in sagemake (embed_shell_sgvm).
     * KEEP prevents the linker discarding it as unreferenced.
     * _shell_sgvm_start/_shell_sgvm_end are read by shell_launch()
     * in kmain.sage at runtime to locate the bytecode.
     */
    .sgvm_shell : {
        _shell_sgvm_start = .;
        KEEP(*(.sgvm_shell))
        _shell_sgvm_end = .;
    } > RAM

    /* Initialised data */
    .data : {
        *(.data .data.*)
        *(.sdata .sdata.*)
    } > RAM

    /* Zero-initialised data */
    .bss : {
        _bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        _bss_end = .;
    } > RAM

    /*
     * Heap / PMM arena boundary symbols.
     * Zero-length section so ld.bfd accepts the assignments cleanly.
     * _heap_end is the top of usable RAM (0x80200000 + 126M - 2M guard
     * = 0x87E00000).  _stack_top shares that address; the boot stub
     * sets sp to _stack_top before calling sage_kernel_main.
     */
    .heap_meta : {
        . = ALIGN(4096);
        _heap_start = .;
        _image_end  = .;
    } > RAM

    _heap_end  = 0x87E00000;
    _stack_top = 0x87E00000;

    /DISCARD/ {
        *(.note*)
        *(.comment)
        *(.eh_frame*)
    }
}
