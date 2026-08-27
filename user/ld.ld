ENTRY(_start)
SECTIONS {
    . = 0x00800000;
    .text : ALIGN(4096) {
        *(.text .text.*)
        *(.rodata .rodata.*)
    }
    . = 0x00801000;
    .data : ALIGN(4096) {
        *(.data .data.*)
        *(.bss .bss.*)
    }
    /DISCARD/ : { *(.note.*) *(.eh_frame .eh_frame_hdr) }
}
