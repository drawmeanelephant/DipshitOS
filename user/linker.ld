/* DipshitOS user program linker script (milestone-three card 6, claim 6783).
 *
 * The user program is a flat AArch64 image (tools/elf2bin.py, DSK1 format —
 * the same tooling as KERNEL.BIN) loaded from the ESP by the kernel's `exec`
 * command. The layout is dense from address 0 with _start first, so the
 * produced flat image is a few hundred bytes and the entry offset is tiny.
 * All addressing inside the payload is PC-relative (adr), so the exact
 * vaddrs chosen here are irrelevant at runtime.
 */
ENTRY(_start)
SECTIONS {
    . = 0x0;
    .text : ALIGN(16) { *(.text .text.*) }
    .rodata : ALIGN(16) { *(.rodata .rodata.*) }
    .data : ALIGN(16) { *(.data .data.*) }
    .bss : ALIGN(16) { *(.bss .bss.*) }
    .ARM.exidx : ALIGN(16) { *(.ARM.exidx*) }
    /* The payload is naked asm — no CFI; keeping the orphan .eh_frame*
     * sections would make them land at VMA 0 (BEFORE .text), so the flat
     * image's entry would point at CFI bytes instead of _start. Discard
     * them so the image is pure code + strings. */
    /DISCARD/ : { *(.note.*) *(.eh_frame .eh_frame_hdr) }
}
