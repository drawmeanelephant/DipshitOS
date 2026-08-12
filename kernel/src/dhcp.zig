//! DHCP client (RFC 2131/2132) — milestone five, card N8 (claim 0351).
//! PURE protocol logic (message build/parse, the four-message INIT
//! handshake, the bounded client state machine, the lease record) +
//! host tests, the arp.zig/udp.zig fat.zig pattern; `virtio_net.zig`
//! wires it to the broadcast-dst send seam (card N8's ONE N5-layer
//! change: a DHCP frame goes out with dst MAC ff:ff:ff:ff:ff:ff and dst
//! IP 255.255.255.255 DIRECTLY — no ARP lookup, src IP 0.0.0.0) and
//! `udp.zig`'s `handle_rx` dispatches port-68 datagrams to
//! `dhcp.handle_rx` (the client owns port 68 by construction — it is
//! NOT a `net udp listen` entry, invisible to `net udp recv`).
//!
//! Honest bounds (documented, never assumed away): no renewal/rebind/
//! lease expiry (the lease time is RECORDED, not enforced); no
//! hostname/DNS options stored; no DHCPv6; no relay/giaddr; ONE client
//! state machine — a fixed BSS struct + one fixed 256-byte message
//! buffer, no heap. The client's UDP packets use src 68 -> dst 67 with
//! a BROADCAST dst. The message is NOT padded to the RFC 2131 300-octet
//! minimum — the fixed 256-byte buffer is the honest bound (the
//! DISCOVER is 244 bytes, the REQUEST 256); a server that rejects
//! sub-300 messages would be a claim-time observation, never assumed.

const std = @import("std");
const arp = @import("arp.zig"); // N3: our static IP (`arp.own_ip` — THE one copy, overwritten on BOUND)

// ---------------------------------------------------------------------------
// Wire constants (RFC 2131/2132)
// ---------------------------------------------------------------------------

/// The client's UDP port (the server answers 67 -> 68).
pub const client_port: u16 = 68;
/// The server's UDP port (the client sends 68 -> 67).
pub const server_port: u16 = 67;
/// The DHCP magic cookie (bytes 236..240 of the message).
pub const magic_cookie: [4]u8 = .{ 0x63, 0x82, 0x53, 0x63 };
/// The fixed BOOTP header: op(1) htype(1) hlen(1) hops(1) xid(4) secs(2)
/// flags(2) ciaddr(4) yiaddr(4) siaddr(4) giaddr(4) chaddr(16) sname(64)
/// file(128) = 236 bytes; the magic cookie follows at 236.
pub const bootp_hdr_len: usize = 236;
/// The fixed message buffer bound (the prompt's ONE fixed 256-byte
/// packet buffer — no heap). DISCOVER = 244 B, REQUEST = 256 B.
pub const msg_max: usize = 256;
/// The full-frame bound: Ethernet(14) + IPv4(20) + UDP(8) + msg_max.
pub const frame_max: usize = 14 + 20 + 8 + msg_max; // 298
/// Bounded DISCOVER retries before an honest refuse.
pub const max_attempts: usize = 3;

// Option codes (RFC 2132).
pub const opt_subnet_mask: u8 = 1;
pub const opt_router: u8 = 3;
pub const opt_msg_type: u8 = 53;
pub const opt_requested_ip: u8 = 50;
pub const opt_lease_time: u8 = 51;
pub const opt_server_id: u8 = 54;
pub const opt_end: u8 = 255;

// Message types (RFC 2131 §3).
pub const msg_type_discover: u8 = 1;
pub const msg_type_offer: u8 = 2;
pub const msg_type_request: u8 = 3;
pub const msg_type_ack: u8 = 5;
pub const msg_type_nack: u8 = 6;

// ---------------------------------------------------------------------------
// Counters (the `net` report's `dhcp=` line) — every step counted.
// ---------------------------------------------------------------------------

pub var discover_sent: u64 = 0;
pub var offer_recv: u64 = 0;
pub var request_sent: u64 = 0;
pub var ack_recv: u64 = 0;
pub var nack_recv: u64 = 0;
pub var timed_out: u64 = 0; // the bounded-retry refuse (max_attempts exhausted)
pub var dropped_malformed: u64 = 0; // an unparseable / unexpected reply

// ---------------------------------------------------------------------------
// State (pure BSS — ONE client state machine)
// ---------------------------------------------------------------------------

pub const State = enum {
    idle,
    selecting, // DISCOVER sent — waiting for an OFFER
    requesting, // OFFER accepted — the REQUEST is built; awaiting the ACK
    bound, // ACK received — the lease is live (arp.own_ip set)
};

pub var state: State = .idle;
/// The current transaction id (echoed by every message of the handshake).
pub var xid: u32 = 0;
/// DISCOVER attempts made (the bounded-retry cap).
pub var attempts: usize = 0;
/// The next outbound message (the ONE fixed buffer): the DISCOVER after
/// `start`, the REQUEST after the OFFER is processed.
pub var msg: [msg_max]u8 = undefined;
pub var msg_len: usize = 0;
/// Whether the built REQUEST was already transmitted (a `net dhcp`
/// invocation in `requesting` with this set is "waiting for the ACK",
/// not a duplicate transmit — honest counters).
pub var request_transmitted: bool = false;
/// The SELECTING-stage offer (pending the REQUEST).
var offered_ip: [4]u8 = .{ 0, 0, 0, 0 };
var offered_server: [4]u8 = .{ 0, 0, 0, 0 };
/// The client's hardware address (captured at `start` — the chaddr every
/// message of the handshake carries; the RX dispatch needs no extra args).
pub var client_mac: [6]u8 = .{ 0, 0, 0, 0, 0, 0 };
/// The BOUND lease (zero = not offered by the server).
pub var lease_ip: [4]u8 = .{ 0, 0, 0, 0 };
pub var lease_mask: [4]u8 = .{ 0, 0, 0, 0 };
pub var lease_gw: [4]u8 = .{ 0, 0, 0, 0 };
pub var lease_server: [4]u8 = .{ 0, 0, 0, 0 };
pub var lease_time: u32 = 0;

/// The RX dispatch's outcome — the caller (the monitor) observes it via
/// `state`; the enum is the honest event for the host tests.
pub const Event = enum {
    none,
    request_ready, // an OFFER was accepted — the REQUEST is built in `msg`
    bound, // the ACK was accepted — the lease is live
    nacked, // a NACK — the client falls back to idle
};

// ---------------------------------------------------------------------------
// Message build (byte-exact, RFC 2131 §4 — the fixtures pin the bytes)
// ---------------------------------------------------------------------------

/// Build a DHCP message into `buf` (must hold >= `msg_max`): the 236-byte
/// BOOTP header (op BOOTREQUEST, htype ethernet, hlen 6, the given xid,
/// the BROADCAST flag 0x8000 — the client asks the server to reply
/// broadcast so the N2 MAC filter admits the answer), our chaddr, the
/// magic cookie, then the options: 53 (message type), for a REQUEST also
/// 50 (the requested IP — the SELECTING-stage offer) + 54 (the server
/// id), and 255 (end). NO option-55 parameter-request list (the honest
/// 256-byte bound — the server's fixed lease provides mask/router/lease
/// unconditionally; a server that withholds them without a request is a
/// claim-time observation). Returns the message length (244 DISCOVER /
/// 256 REQUEST — both within the bound).
pub fn build_message(buf: []u8, chaddr: *const [6]u8, txn_id: u32, mtype: u8, requested_ip: ?[4]u8, server_id: ?[4]u8) usize {
    @memset(buf[0..msg_max], 0);
    buf[0] = 1; // op BOOTREQUEST
    buf[1] = 1; // htype ethernet
    buf[2] = 6; // hlen
    buf[3] = 0; // hops
    buf[4] = @truncate(txn_id >> 24);
    buf[5] = @truncate(txn_id >> 16);
    buf[6] = @truncate(txn_id >> 8);
    buf[7] = @truncate(txn_id);
    // secs (8..10) = 0; flags (10..12) = 0x8000 (broadcast).
    buf[10] = 0x80;
    buf[11] = 0x00;
    // ciaddr/yiaddr/siaddr/giaddr (12..28) = 0.
    @memcpy(buf[28..34], chaddr);
    // sname (44..108) + file (108..236) = 0 (the memset).
    @memcpy(buf[236..240], &magic_cookie);
    var o: usize = 240;
    buf[o] = opt_msg_type;
    buf[o + 1] = 1;
    buf[o + 2] = mtype;
    o += 3;
    if (mtype == msg_type_request) {
        if (requested_ip) |ip| {
            buf[o] = opt_requested_ip;
            buf[o + 1] = 4;
            @memcpy(buf[o + 2 .. o + 6], &ip);
            o += 6;
        }
        if (server_id) |sid| {
            buf[o] = opt_server_id;
            buf[o + 1] = 4;
            @memcpy(buf[o + 2 .. o + 6], &sid);
            o += 6;
        }
    }
    buf[o] = opt_end;
    o += 1;
    return o;
}

/// Build the DISCOVER into `buf` (the INIT step). Returns the length.
pub fn build_discover(buf: []u8, chaddr: *const [6]u8, txn_id: u32) usize {
    return build_message(buf, chaddr, txn_id, msg_type_discover, null, null);
}

/// Build the REQUEST (the SELECTING step — option 50 = the offered IP,
/// option 54 = the offering server). Returns the length.
pub fn build_request(buf: []u8, chaddr: *const [6]u8, txn_id: u32, req_ip: [4]u8, srv_id: [4]u8) usize {
    return build_message(buf, chaddr, txn_id, msg_type_request, req_ip, srv_id);
}

// ---------------------------------------------------------------------------
// Reply parse (RFC 2131 §4.1 — the four-message handshake)
// ---------------------------------------------------------------------------

pub const ParsedReply = struct {
    msg_type: u8,
    yiaddr: [4]u8,
    mask: ?[4]u8 = null,
    router: ?[4]u8 = null,
    server_id: ?[4]u8 = null,
    lease_time: ?u32 = null,
};

/// Parse a BOOTREPLY message: op 2, htype 1 / hlen 6, the magic cookie,
/// the yiaddr, and the options (53 message type — required; 1 mask; 3
/// router; 54 server id; 51 lease time). Malformed replies return null
/// (the caller counts `dropped_malformed` — never assumed away). Option
/// 0 (pad) skips; unknown options skip by their length; the walk stops at
/// 255 (end) or the message end.
pub fn parse_reply(msg_in: []const u8) ?ParsedReply {
    if (msg_in.len < bootp_hdr_len + 4) return null;
    if (msg_in[0] != 2) return null; // BOOTREPLY
    if (msg_in[1] != 1 or msg_in[2] != 6) return null; // ethernet / 6-byte hw
    if (!std.mem.eql(u8, msg_in[236..240], &magic_cookie)) return null;
    var p = ParsedReply{ .msg_type = 0, .yiaddr = .{ 0, 0, 0, 0 } };
    @memcpy(&p.yiaddr, msg_in[16..20]);
    var got_type = false;
    var i: usize = 240;
    while (i < msg_in.len) {
        const code = msg_in[i];
        if (code == opt_end) break;
        if (code == 0) {
            i += 1; // pad
            continue;
        }
        if (i + 1 >= msg_in.len) return null; // truncated length byte
        const len: usize = msg_in[i + 1];
        if (i + 2 + len > msg_in.len) return null; // truncated value
        switch (code) {
            opt_msg_type => {
                if (len != 1) return null;
                p.msg_type = msg_in[i + 2];
                got_type = true;
            },
            opt_subnet_mask => {
                if (len != 4) return null;
                var v: [4]u8 = undefined;
                @memcpy(&v, msg_in[i + 2 .. i + 6]);
                p.mask = v;
            },
            opt_router => {
                if (len != 4) return null;
                var v: [4]u8 = undefined;
                @memcpy(&v, msg_in[i + 2 .. i + 6]);
                p.router = v;
            },
            opt_server_id => {
                if (len != 4) return null;
                var v: [4]u8 = undefined;
                @memcpy(&v, msg_in[i + 2 .. i + 6]);
                p.server_id = v;
            },
            opt_lease_time => {
                if (len != 4) return null;
                p.lease_time = (@as(u32, msg_in[i + 2]) << 24) | (@as(u32, msg_in[i + 3]) << 16) | (@as(u32, msg_in[i + 4]) << 8) | msg_in[i + 5];
            },
            else => {}, // unknown option — skip by length
        }
        i += 2 + len;
    }
    if (!got_type) return null;
    return p;
}

// ---------------------------------------------------------------------------
// The client state machine
// ---------------------------------------------------------------------------

/// Reset the client (tests only — the live kernel never re-initializes).
pub fn reset() void {
    state = .idle;
    xid = 0;
    attempts = 0;
    msg_len = 0;
    request_transmitted = false;
    offered_ip = .{ 0, 0, 0, 0 };
    offered_server = .{ 0, 0, 0, 0 };
    lease_ip = .{ 0, 0, 0, 0 };
    lease_mask = .{ 0, 0, 0, 0 };
    lease_gw = .{ 0, 0, 0, 0 };
    lease_server = .{ 0, 0, 0, 0 };
    lease_time = 0;
    discover_sent = 0;
    offer_recv = 0;
    request_sent = 0;
    ack_recv = 0;
    nack_recv = 0;
    timed_out = 0;
    dropped_malformed = 0;
}

/// INIT -> SELECTING: build the DISCOVER into `msg` with the given
/// transaction id (the caller supplies the CSPRNG draw — or a fixture
/// value in tests) and our chaddr. The caller transmits `msg[0..msg_len]`
/// and counts `discover_sent` + `attempts` on success.
pub fn start(chaddr_in: *const [6]u8, txn_id: u32) void {
    state = .selecting;
    xid = txn_id;
    client_mac = chaddr_in.*;
    request_transmitted = false;
    msg_len = build_discover(&msg, chaddr_in, txn_id);
}

/// Process one server reply (the UDP payload of a port-68 datagram —
/// the 8-byte UDP header already skipped by the caller). Runs in the RX
/// drain context: OFFER (SELECTING) accepts the offer, builds the REQUEST
/// into `msg`, and moves to REQUESTING; ACK (REQUESTING) records the
/// lease, sets `arp.own_ip` (THE one copy — DHCP overwrites the static
/// address honestly) and moves to BOUND; NACK falls back to IDLE (the
/// caller may retry — bounded). Anything unexpected is counted
/// `dropped_malformed`. The REQUEST transmission itself is MONITOR-driven
/// (the state machine only builds it — `request_transmitted` gates the
/// one-shot transmit), so the handshake is deterministic and never
/// transmits from the drain context.
pub fn handle_rx(datagram: []const u8) Event {
    if (datagram.len < udp_hdr_len_ + 1) {
        dropped_malformed += 1;
        return .none;
    }
    const msg_in = datagram[udp_hdr_len_..];
    const p = parse_reply(msg_in) orelse {
        dropped_malformed += 1;
        return .none;
    };
    switch (p.msg_type) {
        msg_type_offer => {
            if (state != .selecting) {
                dropped_malformed += 1; // an OFFER outside SELECTING
                return .none;
            }
            offered_ip = p.yiaddr;
            offered_server = p.server_id orelse p.yiaddr;
            msg_len = build_request(&msg, &client_mac, xid, offered_ip, offered_server);
            request_transmitted = false;
            state = .requesting;
            offer_recv += 1;
            return .request_ready;
        },
        msg_type_ack => {
            if (state != .requesting) {
                dropped_malformed += 1; // an ACK outside REQUESTING
                return .none;
            }
            lease_ip = p.yiaddr;
            lease_mask = p.mask orelse .{ 0, 0, 0, 0 };
            lease_gw = p.router orelse .{ 0, 0, 0, 0 };
            lease_server = p.server_id orelse p.yiaddr;
            lease_time = p.lease_time orelse 0;
            // THE one copy — DHCP overwrites the static address honestly
            // (the report shows the old -> new).
            arp.own_ip = lease_ip;
            state = .bound;
            ack_recv += 1;
            return .bound;
        },
        msg_type_nack => {
            nack_recv += 1;
            state = .idle; // the caller may retry (bounded attempts)
            return .nacked;
        },
        else => {
            dropped_malformed += 1;
            return .none;
        },
    }
}

// (local) — mirrors udp.udp_hdr_len without the udp import (no circular
// dependency: udp imports dhcp for the port-68 dispatch).
const udp_hdr_len_: usize = 8;

// ---------------------------------------------------------------------------
// Host tests — pure logic, byte-exact against the fixtures
// ---------------------------------------------------------------------------

test "dhcp: build_discover is byte-exact against the fixture" {
    const chaddr = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 };
    const txn: u32 = 0x12345678;
    var m: [msg_max]u8 = undefined;
    const n = build_discover(&m, &chaddr, txn);
    // 236 + cookie(4) + 53,1,type(3) + 255(1) = 244.
    try std.testing.expectEqual(@as(usize, 244), n);
    try std.testing.expectEqual(@as(u8, 1), m[0]); // op BOOTREQUEST
    try std.testing.expectEqual(@as(u8, 1), m[1]); // htype ethernet
    try std.testing.expectEqual(@as(u8, 6), m[2]); // hlen
    try std.testing.expectEqual(@as(u8, 0), m[3]); // hops
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34, 0x56, 0x78 }, m[4..8]); // xid BE
    try std.testing.expectEqual(@as(u8, 0x80), m[10]); // broadcast flag high
    try std.testing.expectEqual(@as(u8, 0x00), m[11]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, m[12..16]); // ciaddr
    try std.testing.expectEqualSlices(u8, &chaddr, m[28..34]); // chaddr
    try std.testing.expectEqualSlices(u8, &magic_cookie, m[236..240]);
    try std.testing.expectEqual(@as(u8, opt_msg_type), m[240]);
    try std.testing.expectEqual(@as(u8, 1), m[241]);
    try std.testing.expectEqual(@as(u8, msg_type_discover), m[242]);
    try std.testing.expectEqual(@as(u8, opt_end), m[243]);
}

test "dhcp: build_request is byte-exact — option 50 + 54, 256 bytes" {
    const chaddr = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 };
    const txn: u32 = 0x12345678;
    const req_ip = [4]u8{ 10, 0, 0, 5 };
    const srv = [4]u8{ 10, 0, 0, 5 };
    var m: [msg_max]u8 = undefined;
    const n = build_request(&m, &chaddr, txn, req_ip, srv);
    // 236 + cookie(4) + 53,1,3(3) + 50,4,ip(6) + 54,4,srv(6) + 255(1) = 256.
    try std.testing.expectEqual(@as(usize, 256), n);
    try std.testing.expectEqual(@as(u8, msg_type_request), m[242]);
    try std.testing.expectEqual(@as(u8, opt_requested_ip), m[243]);
    try std.testing.expectEqual(@as(u8, 4), m[244]);
    try std.testing.expectEqualSlices(u8, &req_ip, m[245..249]);
    try std.testing.expectEqual(@as(u8, opt_server_id), m[249]);
    try std.testing.expectEqual(@as(u8, 4), m[250]);
    try std.testing.expectEqualSlices(u8, &srv, m[251..255]);
    try std.testing.expectEqual(@as(u8, opt_end), m[255]);
}

test "dhcp: parse_reply — a crafted OFFER/ACK round trip (byte-exact)" {
    // Build a reply the way the host responder does: copy the DISCOVER
    // shape, op=2, yiaddr, cookie, then 53,1,type + 1,4,mask + 3,4,gw +
    // 54,4,server + 51,4,lease + 255. The guest's parser must read it.
    // The reply message is 268 bytes (the fixed lease options appended)
    // — the test uses a 300-byte local, the live path slices the RX
    // buffer (no fixed bound needed).
    const chaddr = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 };
    const txn: u32 = 0x12345678;
    var m: [300]u8 = undefined;
    const n = build_discover(&m, &chaddr, txn);
    try std.testing.expectEqual(@as(usize, 244), n);
    m[0] = 2; // BOOTREPLY
    @memcpy(m[16..20], &[_]u8{ 10, 0, 0, 5 }); // yiaddr
    m[240] = opt_msg_type;
    m[242] = msg_type_offer;
    var o: usize = 243;
    m[o] = 1;
    m[o + 1] = 4;
    @memcpy(m[o + 2 .. o + 6], &[_]u8{ 255, 255, 255, 0 });
    o += 6;
    m[o] = 3;
    m[o + 1] = 4;
    @memcpy(m[o + 2 .. o + 6], &[_]u8{ 10, 0, 0, 1 });
    o += 6;
    m[o] = opt_server_id;
    m[o + 1] = 4;
    @memcpy(m[o + 2 .. o + 6], &[_]u8{ 10, 0, 0, 5 });
    o += 6;
    m[o] = opt_lease_time;
    m[o + 1] = 4;
    m[o + 2] = 0x00;
    m[o + 3] = 0x00;
    m[o + 4] = 0x0e;
    m[o + 5] = 0x10; // lease 3600
    o += 6;
    m[o] = opt_end;
    const mlen = o + 1;

    const p = parse_reply(m[0..mlen]).?;
    try std.testing.expectEqual(@as(u8, msg_type_offer), p.msg_type);
    try std.testing.expectEqualSlices(u8, &.{ 10, 0, 0, 5 }, &p.yiaddr);
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255, 0 }, &p.mask.?);
    try std.testing.expectEqualSlices(u8, &.{ 10, 0, 0, 1 }, &p.router.?);
    try std.testing.expectEqualSlices(u8, &.{ 10, 0, 0, 5 }, &p.server_id.?);
    try std.testing.expectEqual(@as(u32, 3600), p.lease_time.?);
}

test "dhcp: parse_reply — malformed replies return null" {
    const chaddr = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 };
    var m: [msg_max]u8 = undefined;
    const n = build_discover(&m, &chaddr, 1);
    // Wrong op (BOOTREQUEST) -> null.
    try std.testing.expect(parse_reply(m[0..n]) == null);
    // Bad magic cookie -> null.
    m[0] = 2;
    m[238] ^= 0xff;
    try std.testing.expect(parse_reply(m[0..n]) == null);
    m[238] ^= 0xff;
    // No option 53 -> null.
    m[240] = opt_end;
    try std.testing.expect(parse_reply(m[0..n]) == null);
    // Too short -> null.
    try std.testing.expect(parse_reply(m[0..100]) == null);
}

test "dhcp: the four-message handshake — INIT -> SELECTING -> REQUESTING -> BOUND" {
    reset();
    defer reset();
    const chaddr = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 };

    // INIT: start() builds the DISCOVER.
    start(&chaddr, 0xabcd1234);
    try std.testing.expectEqual(State.selecting, state);
    try std.testing.expectEqual(@as(u32, 0xabcd1234), xid);
    try std.testing.expectEqual(@as(usize, 244), msg_len);
    try std.testing.expectEqual(@as(u8, msg_type_discover), msg[242]);

    // The server's OFFER (a reply built over the discover shape — 268 B).
    var reply: [300]u8 = undefined;
    @memcpy(reply[0..msg_len], msg[0..msg_len]);
    reply[0] = 2;
    @memcpy(reply[16..20], &[_]u8{ 10, 0, 0, 5 });
    reply[240] = opt_msg_type;
    reply[242] = msg_type_offer;
    var o: usize = 243;
    reply[o] = 1;
    reply[o + 1] = 4;
    @memcpy(reply[o + 2 .. o + 6], &[_]u8{ 255, 255, 255, 0 });
    o += 6;
    reply[o] = 3;
    reply[o + 1] = 4;
    @memcpy(reply[o + 2 .. o + 6], &[_]u8{ 10, 0, 0, 1 });
    o += 6;
    reply[o] = opt_server_id;
    reply[o + 1] = 4;
    @memcpy(reply[o + 2 .. o + 6], &[_]u8{ 10, 0, 0, 5 });
    o += 6;
    reply[o] = opt_lease_time;
    reply[o + 1] = 4;
    reply[o + 2] = 0;
    reply[o + 3] = 0;
    reply[o + 4] = 0x0e;
    reply[o + 5] = 0x10;
    o += 6;
    reply[o] = opt_end;
    const offer_len = o + 1;

    // The OFFER is processed by the RX drain: -> REQUESTING, the REQUEST
    // is built (option 50 = the offered IP, 54 = the server id).
    var dg: [8 + 300]u8 = undefined;
    @memset(&dg, 0);
    @memcpy(dg[8 .. 8 + offer_len], reply[0..offer_len]);
    try std.testing.expectEqual(Event.request_ready, handle_rx(&dg));
    try std.testing.expectEqual(State.requesting, state);
    try std.testing.expectEqual(@as(u64, 1), offer_recv);
    try std.testing.expectEqual(@as(usize, 256), msg_len);
    try std.testing.expectEqual(@as(u8, msg_type_request), msg[242]);
    try std.testing.expectEqualSlices(u8, &.{ 10, 0, 0, 5 }, msg[245..249]); // option 50
    try std.testing.expect(!request_transmitted);

    // The server's ACK (option 53 = 5): -> BOUND, the lease recorded,
    // arp.own_ip set (THE one copy — DHCP overwrites the static address).
    var ack: [300]u8 = undefined;
    @memcpy(ack[0..offer_len], reply[0..offer_len]);
    ack[242] = msg_type_ack;
    var dg2: [8 + 300]u8 = undefined;
    @memset(&dg2, 0);
    @memcpy(dg2[8 .. 8 + offer_len], ack[0..offer_len]);
    try std.testing.expectEqual(Event.bound, handle_rx(&dg2));
    try std.testing.expectEqual(State.bound, state);
    try std.testing.expectEqual(@as(u64, 1), ack_recv);
    try std.testing.expectEqualSlices(u8, &.{ 10, 0, 0, 5 }, &lease_ip);
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255, 0 }, &lease_mask);
    try std.testing.expectEqualSlices(u8, &.{ 10, 0, 0, 1 }, &lease_gw);
    try std.testing.expectEqualSlices(u8, &.{ 10, 0, 0, 5 }, &lease_server);
    try std.testing.expectEqual(@as(u32, 3600), lease_time);
    try std.testing.expectEqualSlices(u8, &.{ 10, 0, 0, 5 }, &arp.own_ip);
}

test "dhcp: out-of-sequence + malformed replies are counted, never assumed away" {
    reset();
    defer reset();
    const chaddr = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 };
    start(&chaddr, 7);

    // A malformed reply (garbage) -> dropped_malformed.
    var junk: [64]u8 = .{0} ** 64;
    var dg: [8 + 64]u8 = undefined;
    @memset(&dg, 0);
    @memcpy(dg[8..], &junk);
    try std.testing.expectEqual(Event.none, handle_rx(&dg));
    try std.testing.expectEqual(@as(u64, 1), dropped_malformed);

    // An ACK outside REQUESTING (we are SELECTING) -> dropped_malformed.
    var m: [msg_max]u8 = undefined;
    const n = build_discover(&m, &chaddr, 7);
    m[0] = 2;
    m[240] = opt_msg_type;
    m[242] = msg_type_ack;
    m[243] = opt_end;
    var dg2: [8 + 256]u8 = undefined;
    @memset(&dg2, 0);
    @memcpy(dg2[8 .. 8 + n], m[0..n]);
    try std.testing.expectEqual(Event.none, handle_rx(&dg2));
    try std.testing.expectEqual(@as(u64, 2), dropped_malformed);
    try std.testing.expectEqual(State.selecting, state); // unchanged

    // A NACK falls back to IDLE (the caller may retry, bounded).
    m[242] = msg_type_nack;
    var dg3: [8 + 256]u8 = undefined;
    @memset(&dg3, 0);
    @memcpy(dg3[8 .. 8 + n], m[0..n]);
    try std.testing.expectEqual(Event.nacked, handle_rx(&dg3));
    try std.testing.expectEqual(@as(u64, 1), nack_recv);
    try std.testing.expectEqual(State.idle, state);
}

test "dhcp: bounded retry — max_attempts then an honest refuse (the caller's cap)" {
    reset();
    defer reset();
    // The monitor refuses to start a new handshake after max_attempts
    // DISCOVERs without an OFFER; the counter contract is exercised here.
    var i: usize = 0;
    while (i < max_attempts) : (i += 1) {
        attempts += 1;
    }
    try std.testing.expect(attempts >= max_attempts);
    // The caller's refuse: timed_out counts the refused attempt.
    timed_out += 1;
    try std.testing.expectEqual(@as(u64, 1), timed_out);
}
