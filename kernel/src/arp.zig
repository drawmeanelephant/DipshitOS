//! ARP (RFC 826) over the card-N2 raw-Ethernet seam — milestone five,
//! card N3 (claim 7293). PURE protocol logic (parse / build / classify /
//! bounded table) + host tests, the fat.zig pattern; virtio_net.zig wires
//! it to the transport (the RX drain dispatches ARP frames here, and the
//! N1 `net_send` TX path transmits the replies/requests it builds).
//!
//! Honest bounds: IPv4 ONLY (ptype 0x0800) — no IPv6/other; static IP
//! only (`net ip <a.b.c.d>` — no DHCP, a later card); ONE bounded 4-slot
//! table (fixed BSS, no heap, no allocation); no cache expiry (an entry
//! lives until it is replaced — documented, not assumed); a request for
//! an address we do not own is dropped with a counter (we only answer for
//! our own protocol address).

pub const ethertype_arp: u16 = 0x0806; // Ethernet II ethertype
pub const eth_hdr_len: usize = 14; // dst MAC (6) + src MAC (6) + ethertype (2)
pub const arp_pkt_len: usize = 28; // htype 2 + ptype 2 + hlen 1 + plen 1 + op 2 + sha 6 + spa 4 + tha 6 + tpa 4
/// A complete ARP Ethernet frame: 14-byte header + 28-byte ARP payload.
pub const arp_frame_len: usize = eth_hdr_len + arp_pkt_len; // 42

pub const htype_ethernet: u16 = 0x0001;
pub const ptype_ipv4: u16 = 0x0800;
pub const hlen_ethernet: u8 = 6;
pub const plen_ipv4: u8 = 4;
pub const op_request: u16 = 0x0001;
pub const op_reply: u16 = 0x0002;

/// Bounded ARP table capacity (fixed BSS — no heap, no unbounded growth).
pub const table_slots: usize = 4;

pub const ArpEntry = struct {
    valid: bool = false,
    ip: [4]u8 = .{ 0, 0, 0, 0 },
    mac: [6]u8 = .{ 0, 0, 0, 0, 0, 0 },
};

/// Our static protocol (IPv4) address — fixed BSS, zero = unset. Set by
/// `net ip <a.b.c.d>`; DHCP is a later card (honest bound).
pub var own_ip: [4]u8 = .{ 0, 0, 0, 0 };

/// The bounded peer table (protocol address -> hardware address).
pub var table: [table_slots]ArpEntry = [_]ArpEntry{.{}} ** table_slots;

/// Round-robin cursor for drop-oldest eviction (no timestamps, no heap).
/// `pub` for the cross-module wiring tests (virtio_net resets it).
pub var table_cursor: usize = 0;

/// ARP counters (the `net`/`net arp` reports).
pub var requests_sent: u64 = 0; // ARP requests we transmitted (a resolve miss)
pub var replies_sent: u64 = 0; // replies to requests for OUR protocol address
pub var replies_learned: u64 = 0; // table upserts from incoming replies
pub var dropped: u64 = 0; // malformed / not-for-us / no-IP-set ARP frames
/// Replies we built but could not transmit (the polled TX path timed out
/// honestly — never assumed away).
pub var reply_tx_fail: u64 = 0;

/// Whether a static IP is set (all-zero = unset — a valid 0.0.0.0 is
/// treated as unset; we cannot answer for it and won't send from it).
pub fn ip_set() bool {
    for (own_ip) |b| {
        if (b != 0) return true;
    }
    return false;
}

/// Parse a dotted-quad IPv4 address ("a.b.c.d", each 0..255). Returns
/// null on any malformed component. No heap — the text is scanned in
/// place.
pub fn parse_ip(text: []const u8) ?[4]u8 {
    var out: [4]u8 = .{ 0, 0, 0, 0 };
    var part: u8 = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        if (i == text.len or text[i] == '.') {
            if (part == 4) return null; // more than 4 components
            if (i == start) return null; // empty component
            var v: u32 = 0;
            var j = start;
            while (j < i) : (j += 1) {
                const c = text[j];
                if (c < '0' or c > '9') return null;
                v = v * 10 + (c - '0');
                if (v > 255) return null;
            }
            out[part] = @intCast(v);
            part += 1;
            start = i + 1;
        }
    }
    if (part != 4) return null;
    return out;
}

/// Format an IPv4 address as "a.b.c.d" into `out` (must hold >= 15
/// bytes). Returns the length written (no trailing NUL).
pub fn format_ip(ip: [4]u8, out: *[15]u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        if (i > 0) {
            out[n] = '.';
            n += 1;
        }
        var d = ip[i];
        if (d >= 100) {
            out[n] = '0' + (d / 100);
            n += 1;
            d %= 100;
        }
        if (d >= 10 or ip[i] >= 100) {
            out[n] = '0' + (d / 10);
            n += 1;
            d %= 10;
        }
        out[n] = '0' + d;
        n += 1;
    }
    return n;
}

/// Look up a protocol address in the bounded table. Returns the hardware
/// address or null.
pub fn lookup(ip: [4]u8) ?[6]u8 {
    for (&table) |*e| {
        if (e.valid and std.mem.eql(u8, &e.ip, &ip)) return e.mac;
    }
    return null;
}

/// Upsert (protocol address -> hardware address): update in place on a
/// hit, else fill the first free slot, else drop the oldest entry via a
/// round-robin cursor. No cache expiry (documented honest bound).
pub fn upsert(ip: [4]u8, mac: [6]u8) void {
    for (&table) |*e| {
        if (e.valid and std.mem.eql(u8, &e.ip, &ip)) {
            e.mac = mac;
            return;
        }
    }
    for (&table) |*e| {
        if (!e.valid) {
            e.valid = true;
            e.ip = ip;
            e.mac = mac;
            return;
        }
    }
    const slot = &table[table_cursor];
    table_cursor = (table_cursor + 1) % table_slots;
    slot.valid = true;
    slot.ip = ip;
    slot.mac = mac;
}

// ---------------------------------------------------------------------------
// Frame field accessors (the frame starts at the Ethernet header — dst
// MAC, src MAC, ethertype, then the 28-byte ARP payload).
// ---------------------------------------------------------------------------

/// The Ethernet II ethertype (0 if the frame is too short to carry one).
pub fn ethertype(frame: []const u8) u16 {
    if (frame.len < 14) return 0;
    return (@as(u16, frame[12]) << 8) | frame[13];
}

/// Whether the frame is an ARP frame for OUR medium/protocol (ethernet +
/// IPv4, hlen 6, plen 4) — the shape we can parse. A frame that is not
/// ARP at all returns false too (it is not our concern; the caller's
/// `net recv` seam still observes it).
pub fn is_valid_arp(frame: []const u8) bool {
    if (frame.len < arp_frame_len) return false;
    if (ethertype(frame) != ethertype_arp) return false;
    const htype = (@as(u16, frame[14]) << 8) | frame[15];
    const ptype = (@as(u16, frame[16]) << 8) | frame[17];
    return htype == htype_ethernet and ptype == ptype_ipv4 and frame[18] == hlen_ethernet and frame[19] == plen_ipv4;
}

/// The ARP operation (0 for a non-ARP frame).
pub fn op(frame: []const u8) u16 {
    if (frame.len < 22) return 0;
    return (@as(u16, frame[20]) << 8) | frame[21];
}

pub fn sender_mac(frame: []const u8) [6]u8 {
    var m: [6]u8 = undefined;
    @memcpy(&m, frame[22..28]);
    return m;
}

pub fn sender_ip(frame: []const u8) [4]u8 {
    var ip: [4]u8 = undefined;
    @memcpy(&ip, frame[28..32]);
    return ip;
}

/// Whether the frame is an ARP REQUEST for OUR protocol address (tpa ==
/// own_ip). Requires a static IP to be set — with no IP we cannot answer
/// for any address (honest: dropped by the caller's dispatch).
pub fn is_request_for_us(frame: []const u8) bool {
    if (!is_valid_arp(frame)) return false;
    if (op(frame) != op_request) return false;
    if (!ip_set()) return false;
    if (frame.len < 42) return false;
    return std.mem.eql(u8, frame[38..42], &own_ip);
}

/// Whether the frame is a well-formed ARP REPLY.
pub fn is_reply(frame: []const u8) bool {
    if (!is_valid_arp(frame)) return false;
    return op(frame) == op_reply;
}

/// Build an ARP REQUEST (broadcast dst, our MAC/IP as sender, zeroed
/// target hardware, target protocol = `target_ip`) into `buf` (must hold
/// >= `arp_frame_len` bytes). Returns the frame length (42).
pub fn build_request(buf: []u8, own_mac: *const [6]u8, own_ip_addr: [4]u8, target_ip: [4]u8) usize {
    @memset(buf[0..arp_frame_len], 0);
    @memset(buf[0..6], 0xff); // broadcast dst
    @memcpy(buf[6..12], own_mac); // src
    buf[12] = 0x08;
    buf[13] = 0x06; // ethertype ARP
    buf[14] = 0x00;
    buf[15] = 0x01; // htype ethernet
    buf[16] = 0x08;
    buf[17] = 0x00; // ptype IPv4
    buf[18] = 0x06; // hlen
    buf[19] = 0x04; // plen
    buf[20] = 0x00;
    buf[21] = 0x01; // op request
    @memcpy(buf[22..28], own_mac); // sha
    @memcpy(buf[28..32], &own_ip_addr); // spa
    // tha stays zero (buf[32..38])
    @memcpy(buf[38..42], &target_ip); // tpa
    return arp_frame_len;
}

/// Build an ARP REPLY (unicast dst = `target_mac`, our MAC/IP as sender,
/// target = the requester's MAC/IP) into `buf` (must hold >=
/// `arp_frame_len` bytes). Returns the frame length (42).
pub fn build_reply(buf: []u8, own_mac: *const [6]u8, own_ip_addr: [4]u8, target_mac: [6]u8, target_ip: [4]u8) usize {
    @memset(buf[0..arp_frame_len], 0);
    @memcpy(buf[0..6], &target_mac); // dst = the requester
    @memcpy(buf[6..12], own_mac); // src
    buf[12] = 0x08;
    buf[13] = 0x06; // ethertype ARP
    buf[14] = 0x00;
    buf[15] = 0x01; // htype ethernet
    buf[16] = 0x08;
    buf[17] = 0x00; // ptype IPv4
    buf[18] = 0x06; // hlen
    buf[19] = 0x04; // plen
    buf[20] = 0x00;
    buf[21] = 0x02; // op reply
    @memcpy(buf[22..28], own_mac); // sha
    @memcpy(buf[28..32], &own_ip_addr); // spa
    @memcpy(buf[32..38], &target_mac); // tha
    @memcpy(buf[38..42], &target_ip); // tpa
    return arp_frame_len;
}

/// Process one received Ethernet frame (the caller has already MAC-
/// filtered it and passes the frame WITHOUT the RX virtio_net_hdr — the
/// Ethernet header starts at byte 0). Returns the length of a reply
/// built into `reply_buf` (a request for our protocol address — the
/// caller transmits it), or null (not ARP / a reply learned / dropped).
pub fn handle_rx(frame: []const u8, own_mac: *const [6]u8, reply_buf: []u8) ?usize {
    if (!is_valid_arp(frame)) {
        if (frame.len >= eth_hdr_len and ethertype(frame) == ethertype_arp) dropped += 1; // malformed ARP
        return null;
    }
    if (is_reply(frame)) {
        upsert(sender_ip(frame), sender_mac(frame));
        replies_learned += 1;
        return null;
    }
    if (!is_request_for_us(frame)) {
        dropped += 1; // a request for an address we do not own (or no IP set)
        return null;
    }
    return build_reply(reply_buf, own_mac, own_ip, sender_mac(frame), sender_ip(frame));
}

// ---------------------------------------------------------------------------
// Host tests — pure logic, byte-exact against the RFC fixtures
// ---------------------------------------------------------------------------

const std = @import("std");

const test_mac = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 }; // the host-set guest MAC
const host_mac = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x02 }; // the host-side MAC (fallback_mac)
const ip_guest = [4]u8{ 10, 0, 0, 1 };
const ip_host = [4]u8{ 10, 0, 0, 2 };

test "arp: dotted-quad parse — valid, malformed, out-of-range" {
    try std.testing.expectEqualSlices(u8, &[_]u8{ 10, 0, 0, 1 }, &parse_ip("10.0.0.1").?);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 255, 255, 255 }, &parse_ip("255.255.255.255").?);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0 }, &parse_ip("0.0.0.0").?);
    try std.testing.expect(parse_ip("") == null);
    try std.testing.expect(parse_ip("10.0.0") == null);
    try std.testing.expect(parse_ip("10.0.0.1.2") == null);
    try std.testing.expect(parse_ip("10.0.0.256") == null);
    try std.testing.expect(parse_ip("10..0.1") == null);
    try std.testing.expect(parse_ip("10.0.0.x") == null);
    try std.testing.expect(parse_ip("10.0.0.1 ") == null);
    // format_ip round-trips the canonical shape.
    var text: [15]u8 = undefined;
    const n = format_ip(ip_guest, &text);
    try std.testing.expectEqual(@as(usize, 8), n);
    try std.testing.expectEqualSlices(u8, "10.0.0.1", text[0..n]);
    const n2 = format_ip(.{ 255, 255, 255, 255 }, &text);
    try std.testing.expectEqual(@as(usize, 15), n2);
    try std.testing.expectEqualSlices(u8, "255.255.255.255", text[0..n2]);
}

test "arp: build_request is byte-exact against the fixture" {
    var buf: [arp_frame_len]u8 = undefined;
    const n = build_request(&buf, &test_mac, ip_guest, ip_host);
    try std.testing.expectEqual(@as(usize, 42), n);
    // Ethernet: broadcast dst, our MAC src, ethertype 0x0806.
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }, buf[0..6]);
    try std.testing.expectEqualSlices(u8, &test_mac, buf[6..12]);
    try std.testing.expectEqual(@as(u8, 0x08), buf[12]);
    try std.testing.expectEqual(@as(u8, 0x06), buf[13]);
    // ARP header: htype 1, ptype 0x0800, hlen 6, plen 4, op 1.
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x01 }, buf[14..16]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x08, 0x00 }, buf[16..18]);
    try std.testing.expectEqual(@as(u8, 0x06), buf[18]);
    try std.testing.expectEqual(@as(u8, 0x04), buf[19]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x01 }, buf[20..22]);
    // sha = ours, spa = ours, tha = zero, tpa = target.
    try std.testing.expectEqualSlices(u8, &test_mac, buf[22..28]);
    try std.testing.expectEqualSlices(u8, &ip_guest, buf[28..32]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0, 0, 0 }, buf[32..38]);
    try std.testing.expectEqualSlices(u8, &ip_host, buf[38..42]);
}

test "arp: build_reply is byte-exact against the fixture" {
    var buf: [arp_frame_len]u8 = undefined;
    const n = build_reply(&buf, &test_mac, ip_guest, host_mac, ip_host);
    try std.testing.expectEqual(@as(usize, 42), n);
    // Ethernet: unicast to the requester, our MAC src, ethertype 0x0806.
    try std.testing.expectEqualSlices(u8, &host_mac, buf[0..6]);
    try std.testing.expectEqualSlices(u8, &test_mac, buf[6..12]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x08, 0x06 }, buf[12..14]);
    // ARP header: htype 1, ptype 0x0800, hlen 6, plen 4, op 2.
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x01 }, buf[14..16]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x08, 0x00 }, buf[16..18]);
    try std.testing.expectEqual(@as(u8, 0x06), buf[18]);
    try std.testing.expectEqual(@as(u8, 0x04), buf[19]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x02 }, buf[20..22]);
    // sha/spa = ours; tha/tpa = the requester's.
    try std.testing.expectEqualSlices(u8, &test_mac, buf[22..28]);
    try std.testing.expectEqualSlices(u8, &ip_guest, buf[28..32]);
    try std.testing.expectEqualSlices(u8, &host_mac, buf[32..38]);
    try std.testing.expectEqualSlices(u8, &ip_host, buf[38..42]);
}

test "arp: classify — request-for-us, not-for-us, reply, non-ARP, malformed" {
    own_ip = ip_guest;
    defer own_ip = .{ 0, 0, 0, 0 };
    var req_for_us: [arp_frame_len]u8 = undefined;
    _ = build_request(&req_for_us, &host_mac, ip_host, ip_guest);
    try std.testing.expect(is_valid_arp(&req_for_us));
    try std.testing.expect(is_request_for_us(&req_for_us));
    try std.testing.expect(!is_reply(&req_for_us));

    // A request for a DIFFERENT address is not for us.
    var req_other: [arp_frame_len]u8 = undefined;
    _ = build_request(&req_other, &host_mac, ip_host, .{ 10, 0, 0, 99 });
    try std.testing.expect(is_valid_arp(&req_other));
    try std.testing.expect(!is_request_for_us(&req_other));

    // A reply is a reply, not a request.
    var rep: [arp_frame_len]u8 = undefined;
    _ = build_reply(&rep, &host_mac, ip_host, test_mac, ip_guest);
    try std.testing.expect(is_valid_arp(&rep));
    try std.testing.expect(is_reply(&rep));
    try std.testing.expect(!is_request_for_us(&rep));

    // Non-ARP: ethertype 0x0800 (the N2 known frame shape).
    var ip_frame: [eth_hdr_len + 20]u8 = .{0} ** (eth_hdr_len + 20);
    ip_frame[12] = 0x08;
    ip_frame[13] = 0x00;
    try std.testing.expect(!is_valid_arp(&ip_frame));

    // A short ARP frame is malformed (not valid).
    try std.testing.expect(!is_valid_arp(rep[0..41]));
    // A wrong htype / ptype / hlen / plen is malformed too.
    var bad = rep;
    bad[14] = 0x00;
    bad[15] = 0x02; // htype token-ring
    try std.testing.expect(!is_valid_arp(&bad));
    bad = rep;
    bad[19] = 0x06; // plen 6 (IPv6 — not our shape)
    try std.testing.expect(!is_valid_arp(&bad));

    // No IP set: a request cannot be for us (we cannot answer).
    own_ip = .{ 0, 0, 0, 0 };
    try std.testing.expect(!is_request_for_us(&req_for_us));
}

test "arp: bounded table — lookup, upsert in place, first-free, drop-oldest" {
    // Reset the module table state (BSS is not trusted zeroed).
    table = [_]ArpEntry{.{}} ** table_slots;
    table_cursor = 0;
    try std.testing.expect(lookup(.{ 10, 0, 0, 2 }) == null);

    upsert(.{ 10, 0, 0, 2 }, host_mac);
    try std.testing.expectEqualSlices(u8, &host_mac, &lookup(.{ 10, 0, 0, 2 }).?);

    // Update in place on a hit (same ip, new mac).
    const new_mac = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x09 };
    upsert(.{ 10, 0, 0, 2 }, new_mac);
    try std.testing.expectEqualSlices(u8, &new_mac, &lookup(.{ 10, 0, 0, 2 }).?);
    var count: usize = 0;
    for (&table) |*e| {
        if (e.valid) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count); // no duplicate slot

    // Fill to capacity (first-free slots), then evict the oldest.
    upsert(.{ 10, 0, 0, 3 }, .{ 0x02, 0, 0, 0, 0, 3 });
    upsert(.{ 10, 0, 0, 4 }, .{ 0x02, 0, 0, 0, 0, 4 });
    upsert(.{ 10, 0, 0, 5 }, .{ 0x02, 0, 0, 0, 0, 5 });
    try std.testing.expectEqual(@as(usize, 4), table_slots);
    // A 5th distinct entry evicts one (drop-oldest via the cursor).
    upsert(.{ 10, 0, 0, 6 }, .{ 0x02, 0, 0, 0, 0, 6 });
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x02, 0, 0, 0, 0, 6 }, &lookup(.{ 10, 0, 0, 6 }).?);
    // Exactly one entry was evicted; the rest remain.
    var valid: usize = 0;
    for (&table) |*e| {
        if (e.valid) valid += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), valid);
}

test "arp: handle_rx — answer for us, learn a reply, drop the rest" {
    own_ip = ip_guest;
    table = [_]ArpEntry{.{}} ** table_slots;
    table_cursor = 0;
    requests_sent = 0;
    replies_sent = 0;
    replies_learned = 0;
    dropped = 0;
    reply_tx_fail = 0;
    defer own_ip = .{ 0, 0, 0, 0 };

    var reply_buf: [arp_frame_len]u8 = undefined;

    // A request for OUR address: a byte-exact reply is built.
    var req: [arp_frame_len]u8 = undefined;
    _ = build_request(&req, &host_mac, ip_host, ip_guest);
    const rn = handle_rx(&req, &test_mac, &reply_buf).?;
    try std.testing.expectEqual(@as(usize, 42), rn);
    try std.testing.expectEqualSlices(u8, &host_mac, reply_buf[0..6]); // dst = requester
    try std.testing.expectEqualSlices(u8, &test_mac, reply_buf[6..12]);
    try std.testing.expectEqualSlices(u8, &ip_host, reply_buf[38..42]); // tpa = requester
    try std.testing.expectEqual(@as(u64, 0), replies_sent); // the CALLER sends
    try std.testing.expectEqual(@as(u64, 0), dropped);

    // A request for a DIFFERENT address: dropped, no reply.
    var req_other: [arp_frame_len]u8 = undefined;
    _ = build_request(&req_other, &host_mac, ip_host, .{ 10, 0, 0, 99 });
    try std.testing.expect(handle_rx(&req_other, &test_mac, &reply_buf) == null);
    try std.testing.expectEqual(@as(u64, 1), dropped);

    // An ARP reply: learned into the table, no reply built.
    var rep: [arp_frame_len]u8 = undefined;
    _ = build_reply(&rep, &host_mac, ip_host, test_mac, ip_guest);
    try std.testing.expect(handle_rx(&rep, &test_mac, &reply_buf) == null);
    try std.testing.expectEqual(@as(u64, 1), replies_learned);
    try std.testing.expectEqualSlices(u8, &host_mac, &lookup(ip_host).?);

    // A non-ARP frame: untouched, not counted as dropped.
    var ip_frame: [eth_hdr_len + 20]u8 = .{0} ** (eth_hdr_len + 20);
    ip_frame[12] = 0x08;
    ip_frame[13] = 0x00;
    try std.testing.expect(handle_rx(&ip_frame, &test_mac, &reply_buf) == null);
    try std.testing.expectEqual(@as(u64, 1), dropped);

    // A malformed ARP (short): dropped.
    try std.testing.expect(handle_rx(rep[0..41], &test_mac, &reply_buf) == null);
    try std.testing.expectEqual(@as(u64, 2), dropped);

    // No IP set: a request is not answered (dropped).
    own_ip = .{ 0, 0, 0, 0 };
    try std.testing.expect(handle_rx(&req, &test_mac, &reply_buf) == null);
    try std.testing.expectEqual(@as(u64, 3), dropped);
}
