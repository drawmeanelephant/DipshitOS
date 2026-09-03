// stdz string builder (issue #759): appends raw bytes and formatted u64s
// into a caller-owned region — in the wc app that region is the Z2a mmap
// arena, so strings of runtime-determined size build in heap. Pure — no
// syscalls, no comptime. The flat cross-file namespace (Z3a) gives this
// file fmt_dec / fmt_hex from stdz/fmt.zig with no @import; host-parity
// compiles the modules concatenated (plain // comments only, see fmt.zig).

const Builder = struct {
    buf: [*]u8,
    cap: u64,
    len: u64,
};

pub fn sb_init(b: *Builder, buf: [*]u8, cap: u64) void {
    b.buf = buf;
    b.cap = cap;
    b.len = 0;
}

pub fn sb_len(b: *Builder) u64 {
    return b.len;
}

pub fn sb_append(b: *Builder, src: [*]u8, n: u64) u64 {
    if (b.len + n > b.cap) {
        return b.len;
    }
    var i: u64 = 0;
    const bp: [*]u8 = b.buf;
    while (i < n) {
        bp[b.len + i] = src[i];
        i = i + 1;
    }
    b.len = b.len + n;
    return b.len;
}

pub fn sb_u64(b: *Builder, v: u64) u64 {
    var tmp: [20]u8 = undefined;
    const n: u64 = fmt_dec(v, &tmp);
    return sb_append(b, &tmp, n);
}

pub fn sb_hex(b: *Builder, v: u64) u64 {
    var tmp: [16]u8 = undefined;
    const n: u64 = fmt_hex(v, &tmp);
    return sb_append(b, &tmp, n);
}
