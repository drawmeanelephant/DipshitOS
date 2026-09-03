/* Z4b (issue #761) host link contract -- canonical linker script.
 *
 * Turns `zig build-exe` (aarch64-freestanding) output into an image the
 * VirelaiOS static ELF loader accepts (kernel/src/elf.zig, host-tested):
 *
 *   * exactly 2 PT_LOAD segments: segment 0 R+X at text_base (0x0040_0000)
 *     with .rodata MERGED in (a separate R-only load would be a third
 *     segment / an unwritable second one -- both rejected);
 *   * segment 1 R+W starting EXACTLY at text_base + p_memsz[0] (no
 *     padding gap -- the loader maps data directly after text);
 *   * e_entry = _start inside segment 0's initialized bytes;
 *   * total p_memsz <= 256 KiB (exec_program_max).
 *
 * Used by tools/build-zc-host.sh (the target recipe). The entry symbol
 * comes from the zig root: `export fn _start() callconv(.c) noreturn`
 * calling the fixture's `main`.
 */
ENTRY(_start)
PHDRS {
    text PT_LOAD FLAGS(5); /* R+X: .text + .rodata */
    data PT_LOAD FLAGS(6); /* R+W: .data + .bss */
}
SECTIONS {
    . = 0x00400000;
    .text : ALIGN(16) { *(.text .text.*) } :text
    .rodata : ALIGN(16) { *(.rodata .rodata.*) } :text
    /* Data lands exactly where the text segment's memory image ends. */
    .data : ALIGN(16) { *(.data .data.*) } :data
    .bss : ALIGN(16) { *(.bss .bss.*) } :data
    /DISCARD/ : {
        *(.note .note.*) *(.eh_frame .eh_frame_hdr)
        *(.comment .comment.*) *(.ARM.exidx .ARM.exidx.*)
        *(.got .got.*) *(.plt) *(.rela.*)
    }
}
