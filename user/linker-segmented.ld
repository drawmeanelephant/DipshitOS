/* VirelaiOS SEGMENTED user program linker script (milestone sixteen card C1,
 * claim 3805). Used ONLY for DSK3 images (elf2bin.py --segments); the flat
 * DSK1 programs keep user/linker.ld unchanged.
 *
 * The segmented image carries a read-only+executable text region (`.text` +
 * `.rodata`) and a writable+non-executable data region (`.data` + zeroed
 * `.bss`). `.data` is page-aligned so elf2bin's text/data boundary falls on
 * a 4 KiB page — the loader maps text EL0 read-only + PXN and data+bss
 * EL0 read-write + UXN (W^X both ways), reversing the M15 JINGLE finding (a
 * writable global faulted because the flat image had no writable segment).
 *
 * ADRP/ADD addressing still works: the linker assigns `.data`/`.bss`
 * absolute addresses at base + text_size, and the loader maps the data
 * region at `userspace.text_va + text_size` — the same VA.
 */
ENTRY(_start)
SECTIONS {
    . = 0x00400000;
    .text : ALIGN(16) { *(.text .text.*) }
    .rodata : ALIGN(16) { *(.rodata .rodata.*) }
    . = ALIGN(4096);
    .data : ALIGN(16) { *(.data .data.*) }
    .bss : ALIGN(16) { *(.bss .bss.*) }
    /* The payload is naked asm — no CFI; keep the orphan .eh_frame* and
     * .ARM.exidx sections out so they never form a stray read-only segment
     * after .bss (which would land past the data region and be unmapped). */
    /DISCARD/ : { *(.note.*) *(.eh_frame .eh_frame_hdr) *(.ARM.exidx*) }
}
