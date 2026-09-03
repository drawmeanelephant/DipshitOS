// stdz ring buffer (issue #759): a bounded byte FIFO over a caller-owned
// region (the wc app's mmap arena). Pure — no syscalls, no comptime.
// ring_put returns 1 on success, 0 when full; ring_get returns 256 as the
// empty sentinel (bytes are 0..255). Plain // comments (concatenated
// host-check; see fmt.zig).

const Ring = struct {
    buf: [*]u8,
    cap: u64,
    head: u64,
    tail: u64,
    count: u64,
};

pub fn ring_init(r: *Ring, buf: [*]u8, cap: u64) void {
    r.buf = buf;
    r.cap = cap;
    r.head = 0;
    r.tail = 0;
    r.count = 0;
}

pub fn ring_put(r: *Ring, byte: u64) u64 {
    if (r.count == r.cap) {
        return 0;
    }
    const bp: [*]u8 = r.buf;
    bp[r.head] = @intCast(byte);
    r.head = r.head + 1;
    if (r.head == r.cap) {
        r.head = 0;
    }
    r.count = r.count + 1;
    return 1;
}

pub fn ring_get(r: *Ring) u64 {
    if (r.count == 0) {
        return 256;
    }
    const bp: [*]u8 = r.buf;
    const byte: u64 = @intCast(bp[r.tail]);
    r.tail = r.tail + 1;
    if (r.tail == r.cap) {
        r.tail = 0;
    }
    r.count = r.count - 1;
    return byte;
}
