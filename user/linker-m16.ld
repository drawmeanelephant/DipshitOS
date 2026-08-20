/* DipshitOS user program linker script — Milestone 16 Card C1 (DSK2 multi-segment).
 *
 * Page-aligned segments for proper W^X permission:
 *   .text    at 0x00400000  RX (executable, read-only)
 *   .rodata  at next page   R  (read-only)
 *   .data    at next page   RW (writable data)
 *   .bss     at next page   RW zeroed (BSS)
 *
 * The DSK2 tool preserves PT_LOAD flags, so the kernel can map each with
 * correct AP/UXN/PXN. All sections are PC-relative, so distances between
 * segments (<64 KiB) stay within ADRP range.
 */
ENTRY(_start)
SECTIONS {
    . = 0x00400000;
    /* RX: code + rodata share one executable segment (single PT_LOAD R+X) */
    .text : ALIGN(4096) {
        *(.text .text.*)
        *(.rodata .rodata.*)
        . = ALIGN(4096);
    }
    /* Guard page at 0x401000 (one page unmapped between text and data) — C2 */
    . = 0x402000;
    /* RW: writable data + zeroed BSS (single PT_LOAD RW, memsz>filesz tail is BSS) */
    .data : ALIGN(4096) {
        *(.data .data.*)
        . = ALIGN(4096);
    }
    .bss : ALIGN(4096) {
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(4096);
    }
    .ARM.exidx : ALIGN(16) { *(.ARM.exidx*) }
    /DISCARD/ : { *(.note.*) *(.eh_frame .eh_frame_hdr) }
}
