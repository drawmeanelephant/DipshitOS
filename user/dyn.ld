/* DipshitOS Dynamically Linked Executable linker script (DYNAPP.BIN, claim 7921).
 */
ENTRY(_start)
SECTIONS {
    . = 0x00400000;
    .interp : { KEEP(*(.interp)) }
    .text : ALIGN(16) { *(.text .text.*) }
    .rodata : ALIGN(16) { *(.rodata .rodata.*) }
    .dynamic : ALIGN(16) { *(.dynamic) }
    .got : ALIGN(16) { *(.got .got.plt) }
    .data : ALIGN(16) { *(.data .data.*) }
    .bss : ALIGN(16) { *(.bss .bss.*) }
    /DISCARD/ : { *(.note.*) *(.eh_frame .eh_frame_hdr) }
}
