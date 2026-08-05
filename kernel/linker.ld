/* DipshitOS kernel linker script.
 *
 * The default lld layout aligns LOAD segments to the 64 KiB max page size,
 * which would pad the flat kernel image (KERNEL.BIN) with ~64 KiB of zeros.
 * This script lays the loadable sections out densely from address 0, so the
 * produced image is a few hundred bytes. _start (the kernel entry) is placed
 * first, making the entry point sit at image base + 0.
 *
 * The kernel is only ever loaded as a flat image (tools/elf2bin.py) at a
 * 4K-aligned address; all addressing is PC-relative, so the exact vaddrs
 * chosen here are irrelevant at runtime. See docs/decisions/
 * 0002-kernel-handoff.md.
 */
ENTRY(_start)
SECTIONS {
    . = 0x0;
    .text : ALIGN(16) { *(.text .text.*) }
    .rodata : ALIGN(16) { *(.rodata .rodata.*) }
    .data.rel.ro : ALIGN(16) { *(.data.rel.ro .data.rel.ro.*) }
    .eh_frame : ALIGN(16) { *(.eh_frame .eh_frame_hdr) }
    .data : ALIGN(16) { *(.data .data.*) }
    .bss : ALIGN(16) { *(.bss .bss.*) }
    .ARM.exidx : ALIGN(16) { *(.ARM.exidx*) }
    /DISCARD/ : { *(.note.*) }
}
