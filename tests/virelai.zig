//! virelai.zig — host-author shim for the frozen WASM `env.*` import
//! contract (docs/wasm-import-contract.md, W1a #778). Thin spelling ONLY:
//! the contract document is the ABI, not this file. Zig sibling of
//! tests/virelai.h.
//!
//! On wasm targets Zig lowers `extern "env" fn ...` declarations to wasm
//! imports from module `env` under the DECLARATION's own name — so the
//! decls below carry the bare contract names from §5 (`env.write`,
//! `env.file_open`, …), not a `v_` prefix (C needs the prefix to dodge
//! libc; Zig authors reach the shim through a namespace instead). No
//! hand-written WAT, no libc, no POSIX.
//!
//! A freestanding Zig app links them by importing this file, e.g.:
//!
//!     const v = @import("virelai.zig");
//!     export fn _start() noreturn {
//!         const msg = "hi from zig\n";
//!         _ = v.write(1, msg.ptr, msg.len);
//!         v.exit(0);
//!     }
//!
//! compiled with (Zig provides the wasm entry machinery; `export fn
//! _start` is the symbol wasm-ld wants):
//!
//!     zig build-exe -target wasm32-freestanding -O ReleaseSmall \
//!         -fstrip app.zig -o app.wasm
//!
//! Inspect with `wasm-objdump -x app.wasm` — imports must be exactly the
//! frozen `env.*` surface from contract §5.
//!
//! NOTE on parameter spelling: the contract signatures are wasm `i32`
//! (pointers are i32 offsets into the single linear memory — §3). Zig's
//! `[*]const u8`/`[*]u8` lower to i32 on wasm32; lengths are `u32`
//! (mirroring the C shim's `unsigned long` = 32-bit on wasm32). Where the
//! C shim shows `void*`/`char*` buffers, use the pointer types below; the
//! interpreter validates `ptr + len` inside the store before touching
//! memory, and zero-length slices with any pointer are valid (§3).

/// §5.1 file MODE_* flags (ADR 0010 D2)
pub const V_MODE_READ: u32 = 0x1;
pub const V_MODE_WRITE: u32 = 0x2;
pub const V_MODE_CREATE: u32 = 0x4;
pub const V_MODE_APPEND: u32 = 0x8;
pub const V_MODE_DIR: u32 = 0x10;

/// §5.5 mmap constants (same values as the kernel)
pub const V_PROT_READ: u32 = 1;
pub const V_PROT_WRITE: u32 = 2;
pub const V_PROT_EXEC: u32 = 4;
pub const V_MAP_PRIVATE: u32 = 0x02;
pub const V_MAP_ANONYMOUS: u32 = 0x20;
pub const V_MAP_POPULATE: u32 = 0x8000;

/// W2 debug pair (contract §7)
pub extern "env" fn write(fd: u32, buf: [*]const u8, n: u32) i32;
pub extern "env" fn exit(status: i32) noreturn;

/// §5.1 file — slots 23–27 + 34–37
pub extern "env" fn file_open(path: [*]const u8, path_len: u32, flags: u32) i32;
pub extern "env" fn file_read(fd: i32, buf: [*]u8, cap: u32) i32;
pub extern "env" fn file_write(fd: i32, buf: [*]const u8, len: u32) i32;
pub extern "env" fn file_close(fd: i32) i32;
pub extern "env" fn dir_list(path: [*]const u8, path_len: u32, out: [*]u8, max_entries: u32) i32;
pub extern "env" fn file_delete(path: [*]const u8, path_len: u32) i32;
pub extern "env" fn file_rename(old_p: [*]const u8, old_len: u32, new_p: [*]const u8, new_len: u32) i32;
pub extern "env" fn file_truncate(fd: i32, size: u32) i32;
pub extern "env" fn file_free(volume: u32) i32;

/// §5.2 window — slots 12–20 (ids 2..5, kernel-owned back-buffers)
pub extern "env" fn win_open(x: u32, y: u32, w: u32, h: u32) i32;
pub extern "env" fn win_fill(id: i32, x: u32, y: u32, w: u32, h: u32, rgb: u32) i32;
pub extern "env" fn win_present(id: i32) i32;
pub extern "env" fn win_close(id: i32) i32;
pub extern "env" fn win_move(id: i32, x: u32, y: u32) i32;
pub extern "env" fn win_raise(id: i32) i32;
pub extern "env" fn win_get(id: i32, out: [*]u8) i32;
pub extern "env" fn win_query(id: i32, out: [*]u8) i32;
pub extern "env" fn win_set_visible(id: i32, visible: u32) i32;

/// §5.3 audio — slots 42–45
pub extern "env" fn audio_info(out: [*]u8) i32;
pub extern "env" fn audio_play(buf: [*]const u8, len: u32) i32;
pub extern "env" fn audio_volume(vol: u32) i32;
pub extern "env" fn audio_mute(muted: u32) i32;

/// §5.4 timers — slots 40/41 (delivery via the interpreter's event pump)
pub extern "env" fn timer_set(delay_ticks: u32) i32;
pub extern "env" fn timer_cancel() i32;

/// §5.5 mmap arena — slot 63 (+ munmap 64, same contract row); separate
/// from memory.grow
pub extern "env" fn mmap(addr: u32, len: u32, prot: u32, flags: u32) i32;
pub extern "env" fn munmap(addr: u32, len: u32) i32;

/// §5.6/5.7 processes + wait — slots 7/8
pub extern "env" fn procs(buf: [*]u8, max: u32) i32;
pub extern "env" fn wait(pid: u32) i32;

/// §5.1 DirEntry — 40 bytes LE (NOT the HF2 file-channel LIST row)
pub const VDirEntry = extern struct {
    name: [32]u8, // NUL-padded, truncated host name
    size: u32, // file bytes; 0 for dirs
    is_dir: u8, // 0 = file, 1 = directory
    reserved: [3]u8,
};
comptime {
    if (@sizeOf(VDirEntry) != 40) @compileError("VDirEntry must be 40 bytes");
}

/// §5.3 AudioInfo — 16 bytes LE
pub const VAudioInfo = extern struct {
    ready: u32, // 0/1; first call drives probe+SET_PARAMS
    format: u8, // FMT_* code (0xff = none)
    rate: u8, // RATE_* code (0xff = none)
    channels: u8, // 1 or 2
    padding: u8,
    period_bytes: u32,
    max_len: u32, // 64 KiB
};
comptime {
    if (@sizeOf(VAudioInfo) != 16) @compileError("VAudioInfo must be 16 bytes");
}
