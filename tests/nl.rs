//! nl.rs — post-M35 cross-language author proof (claim 4912): a numbered-
//! lines tool (`nl`, cat -n shape) authored in **Rust** from
//! docs/wasm-import-contract.md alone and compiled with
//! `rustc --target wasm32-unknown-unknown` — no virelai header, no WAT,
//! no libc, no WASI. Rust's wasm spelling of the contract is
//! `#[link(wasm_import_module = "env")] extern "C"` declarations written
//! straight from the §5 rows.
//!
//! Provenance (same discipline as tests/wc.c): §5.1 rows gave
//! env.file_open/file_read/file_close (fd semantics, EOF returns 0,
//! cap-clamped reads, negative returns are −errno per §4), §3 said paths
//! are byte slices (`path_ptr/path_len`), and §7's `write(1, ...)` +
//! `exit(status)` debug pair covers the console. No interpreter source
//! was read while authoring. The only out-of-band fact is the W3+ fixture
//! path convention `/host/WC.TXT` (wasm `_start` takes no argv).
//!
//! Semantics: reads `/host/WC.TXT` in 64-byte env.file_read chunks into a
//! bounded 2048-byte line buffer (the kernel's staging cap, §5.1),
//! splits on `\n`, tolerates CRLF (`\r\n` — the `\r` is line terminator,
//! not content, so the console stream stays clean), prints each line
//! right-aligned `%6d` + two spaces, and exits with the total output byte
//! count (fileapp's length proof). Error exits: 51 open failed, 52 read
//! failed, 53 line over the 2048 cap (fileapp 31/32/33, wc 41/42
//! discipline). Counts are cross-validated against an independent Python
//! reimplementation of the same fixture split.
//!
//! Native cross-run: `rustc -O nl.rs -o nl-native` runs the SAME
//! counting/printing code against a host file path (argv[1]) — the wasm
//! `imp` module is cfg'd out and replaced with std-backed imports.
#![cfg_attr(target_arch = "wasm32", no_std)]
#![cfg_attr(target_arch = "wasm32", no_main)]

/// The frozen `env.*` surface this app uses — spelled per language:
/// wasm32 imports (the real module) vs. std-backed fakes for the native
/// cross-run. The tool code below never sees the difference.
#[cfg(target_arch = "wasm32")]
mod imp {
    // Contract §5: env.write / env.exit are the §7 debug pair;
    // env.file_open/file_read/file_close are §5.1 slots 23/24/26. All
    // wasm signatures are i32 (pointers are i32 offsets — §3).
    #[link(wasm_import_module = "env")]
    extern "C" {
        pub fn write(fd: i32, buf: *const u8, n: u32) -> i32;
        pub fn exit(status: i32) -> !;
        pub fn file_open(path: *const u8, path_len: u32, flags: u32) -> i32;
        pub fn file_read(fd: i32, buf: *mut u8, cap: u32) -> i32;
        pub fn file_close(fd: i32) -> i32;
    }
    /// §5.1 MODE_READ bit (ADR 0010 D2).
    pub const V_MODE_READ: u32 = 0x1;
}

#[cfg(not(target_arch = "wasm32"))]
mod imp {
    // Native cross-run harness (host side, std allowed): the same §5
    // signatures backed by real files so the tool logic is exercised
    // identically before anything is pinned.
    use std::fs::File;
    use std::io::{Read, Write};
    use std::process;

    pub const V_MODE_READ: u32 = 0x1;

    static mut G_FILE: Option<File> = None;

    pub unsafe fn write(_fd: i32, buf: *const u8, n: u32) -> i32 {
        let s = std::slice::from_raw_parts(buf, n as usize);
        let _ = std::io::stdout().write_all(s);
        n as i32
    }
    pub unsafe fn exit(status: i32) -> ! {
        process::exit(status);
    }
    pub unsafe fn file_open(path: *const u8, path_len: u32, _flags: u32) -> i32 {
        let bytes = std::slice::from_raw_parts(path, path_len as usize);
        let p = String::from_utf8_lossy(bytes).into_owned();
        match File::open(&p) {
            Ok(f) => {
                G_FILE = Some(f);
                1
            }
            Err(_) => -1,
        }
    }
    pub unsafe fn file_read(_fd: i32, buf: *mut u8, cap: u32) -> i32 {
        let out = std::slice::from_raw_parts_mut(buf, cap as usize);
        match G_FILE.as_mut().map(|f| f.read(out)) {
            Some(Ok(n)) => n as i32,
            _ => -1,
        }
    }
    pub unsafe fn file_close(_fd: i32) -> i32 {
        G_FILE = None;
        0
    }
}

/// Safe wrappers over the raw imports — one call shape for both targets.
mod api {
    use super::imp;

    pub fn write(buf: &[u8]) {
        unsafe { imp::write(1, buf.as_ptr(), buf.len() as u32) };
    }
    pub fn exit(status: i32) -> ! {
        unsafe { imp::exit(status) }
    }
    pub fn file_open(path: &[u8], flags: u32) -> i32 {
        unsafe { imp::file_open(path.as_ptr(), path.len() as u32, flags) }
    }
    pub fn file_read(fd: i32, buf: &mut [u8]) -> i32 {
        unsafe { imp::file_read(fd, buf.as_mut_ptr(), buf.len() as u32) }
    }
    pub fn file_close(fd: i32) -> i32 {
        unsafe { imp::file_close(fd) }
    }
}

/// The tool: number every `\n`-terminated line of `fd`, 2048-byte bound
/// (the kernel staging cap, §5.1). Returns the total output byte count
/// (the exit status). A final unterminated line is still numbered —
/// reading stops at EOF (read returns 0, §5.1).
fn nl_run(fd: i32) -> u32 {
    let mut chunk = [0u8; 64];
    let mut line = [0u8; 2048];
    let mut len: usize = 0;
    let mut total: u32 = 0;
    let mut printed: u32 = 0;
    loop {
        let n = api::file_read(fd, &mut chunk);
        if n < 0 {
            api::write(b"nl: read failed\n");
            api::exit(52);
        }
        if n == 0 {
            break; // EOF — contract §5.1
        }
        for &b in &chunk[0..n as usize] {
            if b == b'\n' {
                // CRLF tolerance: a trailing \r before the \n is line
                // terminator, not content (keeps the console byte-clean).
                let mut end = len;
                if end > 0 && line[end - 1] == b'\r' {
                    end -= 1;
                }
                total += put_line(printed + 1, &line[..end]);
                printed += 1;
                len = 0;
            } else {
                if len == 2048 {
                    api::write(b"nl: line over 2048-byte cap\n");
                    api::exit(53);
                }
                line[len] = b;
                len += 1;
            }
        }
    }
    // Unterminated final line (no trailing \n in the file).
    if len > 0 {
        total += put_line(printed + 1, &line[..len]);
    }
    total
}

/// Emit one `%6d  <content>\n` line; returns its byte count.
fn put_line(num: u32, content: &[u8]) -> u32 {
    let mut out = [0u8; 2056];
    let mut o = 0;
    // Right-align `num` in 6 columns.
    let mut digs = [0u8; 8];
    let mut d = 0;
    let mut v = num;
    loop {
        digs[d] = b'0' + (v % 10) as u8;
        d += 1;
        v /= 10;
        if v == 0 {
            break;
        }
    }
    while o < 6 - d as usize {
        out[o] = b' ';
        o += 1;
    }
    while d > 0 {
        d -= 1;
        out[o] = digs[d as usize];
        o += 1;
    }
    out[o] = b' ';
    out[o + 1] = b' ';
    o += 2;
    out[o..o + content.len()].copy_from_slice(content);
    o += content.len();
    out[o] = b'\n';
    o += 1;
    api::write(&out[..o]);
    o as u32
}

/// wasm entry (exported `_start`, no argv — path is fixed per W3+).
#[cfg(target_arch = "wasm32")]
#[no_mangle]
pub extern "C" fn _start() {
    let path: &[u8] = b"/host/WC.TXT";
    let fd = api::file_open(path, imp::V_MODE_READ);
    if fd < 0 {
        api::write(b"nl: open failed\n");
        api::exit(51);
    }
    let total = nl_run(fd);
    api::file_close(fd);
    api::exit(total as i32);
}

/// Native entry (host cross-run): same tool over argv[1].
#[cfg(not(target_arch = "wasm32"))]
fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 2 {
        std::process::exit(2);
    }
    let fd = api::file_open(args[1].as_bytes(), imp::V_MODE_READ);
    if fd < 0 {
        api::exit(3);
    }
    let total = nl_run(fd);
    api::file_close(fd);
    api::exit(total as i32);
}

#[cfg(target_arch = "wasm32")]
#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    loop {}
}
