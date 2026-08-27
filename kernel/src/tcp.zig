//! TCP client (RFC 793) over the card-N4 IPv4 seam — milestone five,
//! card N10 (claim 7026). PURE protocol logic (segment build/parse, the
//! IPv4 pseudo-header checksum, the bounded client state machine, the
//! four-segment lifecycle SYN -> SYN-ACK -> (data <-> echo) -> FIN ->
//! FIN-ACK -> final ACK, the bounded connect timeout) + host tests, the
//! dhcp.zig/udp.zig fat.zig pattern; `ipv4.zig` wires it to
//! ALREADY-VALIDATED IPv4 frames (protocol 6 dispatch — the IPv4
//! checksum/fragment/dst checks stay in ipv4, never duplicated) and
//! `virtio_net.zig`'s `net_tcp_send` drives the transmit side (the N1
//! one-request-at-a-time TX path).
//!
//! Honest bounds (documented, never assumed away): BOUNDED
//! retransmission (card N11, claim 5357 — a SYN/data/FIN with no ACK
//! is retransmitted on a FIXED 3 s RTO of guest ticks, at most
//! `retx_max` = 10 times, then the connection ABORTS honestly —
//! counted `retx_aborted`; bare ACKs are NEVER retransmitted; the 30 s
//! connect timeout remains the SYN's outer bound — the retransmission
//! abort at 33 s never beats it, so the N10 refusal is byte-exact;
//! every retransmission is byte-identical — the pending segment copy —
//! and counted `retransmitted`; an ACK covering everything the client
//! sent clears the pending state, so an acknowledged segment is never
//! retransmitted); ONE bounded connect timeout (30 s of guest ticks —
//! the card-N9 timer pattern — a SYN with no SYN-ACK refuses honestly,
//! counted `timed_out`); NO TCP options (a bare 20-byte header — no
//! MSS, no window scaling, no SACK, no timestamps — a segment with a
//! data offset != 5 is DROPPED, counted); a FIXED window (4096); no
//! segmentation (payload <= `payload_max`, truncated honestly on TX);
//! no reassembly (ONE bounded RX segment — a second unread segment is
//! DROPPED, counted, never overwritten silently); NO TCP loopback (the
//! client connects OUTWARD only — an own-IP connect is refused
//! `.no_peer` like an unresolved peer); no server surface, no port
//! listening, no urgent data, no congestion control, no adaptive RTO
//! (a fixed timer — no Karn's algorithm, no exponential backoff). The
//! close is client-driven (FIN -> FIN-ACK -> final ACK); a clean
//! server FIN+ACK in ESTABLISHED is ACKed and counted
//! (`finack_recv`), and the caller's `net tcp close` then completes
//! the close; anything else is counted `dropped_malformed`. The fixed
//! source port is 8000 (the UDP layer's 7000 analog — deterministic,
//! gate-assertable).

const std = @import("std");
const arp = @import("arp.zig"); // N3: our static IP (`arp.own_ip` — the ONE copy)

// ---------------------------------------------------------------------------
// Wire constants (RFC 793)
// ---------------------------------------------------------------------------

/// The IP protocol number for TCP.
pub const protocol_tcp: u8 = 6;
pub const eth_hdr_len: usize = 14; // the same values as ipv4.zig (constants only — no circular import)
pub const ipv4_hdr_len: usize = 20;
/// The TCP header WITHOUT options (the honest bound — offset 5 only).
pub const tcp_hdr_len: usize = 20;
/// The fixed source port for the client (deterministic, gate-assertable —
/// the UDP layer's `default_src_port` 7000 analog).
pub const default_src_port: u16 = 8000;
/// Bounded payload per segment (the N5 `payload_max` bound — honest
/// truncation on TX; a longer RX payload is dropped, counted).
pub const payload_max: usize = 64;
/// The segment buffer bound: 20-byte header + the bounded payload.
pub const segment_max: usize = tcp_hdr_len + payload_max; // 84
/// The largest full frame: Ethernet + IPv4 + the bounded segment.
pub const frame_max: usize = eth_hdr_len + ipv4_hdr_len + segment_max; // 118
/// The smallest full frame: Ethernet + IPv4 + the 20-byte header.
pub const frame_min: usize = eth_hdr_len + ipv4_hdr_len + tcp_hdr_len; // 54
/// The fixed advertised window (no window scaling — honest bound).
pub const window: u16 = 4096;
/// The connect timeout in guest seconds (the 1 Hz generic timer — the
/// card-N9 lease-clock pattern). A SYN with no SYN-ACK after this long
/// refuses honestly (`timed_out`), releasing the connection state. Card
/// N11 keeps this as the SYN's OUTER bound: the retransmission abort
/// fires at (retx_max + 1) * rto = 33 s > 30 s, so the N10 refusal is
/// byte-exact.
pub const connect_timeout: u64 = 30;
/// The fixed retransmission timeout in guest seconds (card N11, claim
/// 5357). A SYN/data/FIN with no ACK is retransmitted when its RTO
/// expires — a fixed timer (no adaptive estimation, no Karn's
/// algorithm, no exponential backoff — the honest bound).
pub const rto_ticks: u64 = 3;
/// The retransmission bound (card N11): a segment is retransmitted at
/// most `retx_max` times (11 transmissions total), then the connection
/// ABORTS honestly (`retx_aborted`), releasing the state. The abort
/// fires at (retx_max + 1) * rto = 33 s of guest ticks — after the 30 s
/// connect timeout, so the SYN's outer bound is unchanged.
pub const retx_max: u64 = 10;

// Flags (RFC 793 §3.1 — the 9-bit flag field; only the ones we use).
pub const flag_fin: u8 = 0x01;
pub const flag_syn: u8 = 0x02;
pub const flag_rst: u8 = 0x04;
pub const flag_ack: u8 = 0x10;

// ---------------------------------------------------------------------------
// Counters (the `net` report's `tcp=` line) — every step counted.
// ---------------------------------------------------------------------------

pub var syn_sent: u64 = 0; // SYN segments transmitted (a connect attempt)
pub var synack_recv: u64 = 0; // the handshake SYN-ACK accepted
pub var ack_sent: u64 = 0; // bare ACK segments transmitted (handshake / echo / final)
pub var data_sent: u64 = 0; // data segments transmitted (`net tcp send`)
pub var data_recv: u64 = 0; // payload segments accepted into the RX buffer
pub var fin_sent: u64 = 0; // FIN segments transmitted (`net tcp close`)
pub var finack_recv: u64 = 0; // FIN-ACK segments received (the close answer / a server FIN)
pub var rst_sent: u64 = 0; // RST segments transmitted (`net tcp reset`)
pub var rst_recv: u64 = 0; // RST segments received (the connection died)
pub var timed_out: u64 = 0; // the bounded connect timeout refused
pub var retransmitted: u64 = 0; // segment retransmissions (card N11 — the `retx=` counter)
pub var retx_aborted: u64 = 0; // the retransmission bound aborted the connection (the `abort=` counter)
pub var dropped_badsum: u64 = 0; // the TCP checksum mismatch (pseudo-header + segment)
pub var dropped_malformed: u64 = 0; // an unparseable / unexpected / out-of-bounds segment

// ---------------------------------------------------------------------------
// State (pure BSS — ONE client connection)
// ---------------------------------------------------------------------------

pub const State = enum {
    idle,
    listen, // passive open — listening for incoming connection
    syn_sent, // the SYN went out — awaiting the SYN-ACK
    syn_received, // incoming SYN received — SYN-ACK sent, awaiting ACK
    established, // the handshake ACK went out — data can flow
    fin_sent, // the FIN went out — awaiting the FIN-ACK
    closed, // the close completed (clean FIN-ACK) or a RST killed the connection
};

pub var state: State = .idle;
pub var listen_port: u16 = 0;
pub var is_server: bool = false;
/// The peer: its IP, port, and MAC (the caller resolved the MAC with
/// `net arp <ip>` — the seam resolves nothing).
pub var peer_ip: [4]u8 = .{ 0, 0, 0, 0 };
pub var peer_port: u16 = 0;
pub var peer_mac: [6]u8 = .{ 0, 0, 0, 0, 0, 0 };
/// The client's initial sequence number (CSPRNG-drawn at connect — real
/// TCP randomizes ISNs; the gate asserts the SYN's seq and the ACK chain
/// structurally, not by value).
pub var isn: u32 = 0;
/// The server's ISN (from the accepted SYN-ACK).
pub var srv_isn: u32 = 0;
/// The next sequence number the client will send (snd_una; the SYN and
/// FIN each consume one sequence number).
pub var snd_una: u32 = 0;
/// The next sequence number the client expects to receive.
pub var rcv_nxt: u32 = 0;
/// The next outbound segment (the ONE fixed buffer — the SYN, the
/// handshake ACK, a data segment, a bare ACK, the FIN, the RST, the
/// final ACK — built by the state machine, transmitted by the monitor).
pub var msg: [segment_max]u8 = undefined;
pub var msg_len: usize = 0;
/// A built ACK segment is waiting to be transmitted (the RX processing
/// builds it; the monitor transmits it on the next `net tcp` — the
/// polled-drain contract, never a transmit from the drain context).
pub var ack_pending: bool = false;
/// The bounded RX buffer (ONE segment — no reassembly, honest bound).
pub var rx_payload: [payload_max]u8 = undefined;
pub var rx_len: usize = 0;
pub var rx_pending: bool = false;
/// The connect-timeout clock. The caller (the shell idle loop + `net
/// tcp`) stamps `now_ticks` from the 1 Hz generic timer (`timer.ticks`
/// — seconds) each poll; `start` stamps `syn_ticks`, so the elapsed
/// connect time is honest wall-clock seconds.
pub var now_ticks: u64 = 0;
pub var syn_ticks: u64 = 0;
/// Card N11 (claim 5357) — the bounded retransmission state. ONE
/// pending-unacknowledged segment (the polled-drain contract: at most
/// ONE unacked TX in flight — the retransmission buffer is the bounded
/// `segment_max` copy, never a second allocation). `tx_pending` is set
/// by `record_pending` after a sequence-consuming segment (SYN/data/FIN)
/// is transmitted and cleared when an ACK covers it (the `handle_rx`
/// paths) or the connection dies (RST / timeout / abort / reset). Bare
/// ACKs are NEVER recorded — they are never retransmitted (the honest
/// bound).
pub var tx_pending: bool = false;
pub var retx_msg: [segment_max]u8 = undefined;
pub var retx_len: usize = 0;
/// When the pending segment was last transmitted (initial + each
/// retransmission) — the RTO clock, stamped by `record_pending` and the
/// retransmit itself.
pub var tx_ticks: u64 = 0;
pub var retx_count: u64 = 0; // retransmissions of the CURRENT pending segment

/// The RX dispatch's outcome — the caller (the monitor) observes it via
/// `state`; the enum is the honest event for the host tests.
pub const Event = enum {
    none,
    synack_recv, // the handshake SYN-ACK accepted — the ACK is built (ack_pending)
    data_recv, // a payload segment accepted — buffered, the ACK is built
    finack_recv, // a FIN-ACK received — the final ACK (or an echo ACK) is built
    rst_recv, // a RST — the connection died
};

/// The RTO poll's outcome (card N11, claim 5357) — the caller (the
/// shell idle loop) observes it; `.retransmit` means `msg` holds the
/// rebuilt pending segment (transmit it + print), `.abort` means the
/// retransmission bound released the connection (print).
pub const RtoEvent = enum {
    none,
    retransmit,
    abort,
};

// ---------------------------------------------------------------------------
// RFC 1071 one's-complement checksum (the udp.zig machinery, protocol 6 —
// the IPv4 pseudo-header per RFC 793 §3.1)
// ---------------------------------------------------------------------------

fn sum_words(data: []const u8) u32 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < data.len) : (i += 2) {
        sum += (@as(u32, data[i]) << 8) | data[i + 1];
    }
    if (i < data.len) sum += @as(u32, data[i]) << 8; // trailing odd byte
    return sum;
}

fn fold(sum: u32) u16 {
    var s = sum;
    while (s >> 16 != 0) s = (s & 0xffff) + (s >> 16);
    return ~@as(u16, @truncate(s));
}

/// The TCP checksum over the IPv4 pseudo-header (src IP, dst IP, zero,
/// protocol 6, TCP length) + the segment (`segment` = the 20-byte header
/// + payload; the checksum field must be ZEROED by the caller when
/// building — the verification path passes the field as read). Word 5 is
/// bytes 8-9 = 0x00 0x06 (the ZERO byte HIGH, protocol 6 LOW — the RFC
/// layout; a reversed byte order here silently breaks every segment
/// against standard peers, caught by the live gate's byte-exact
/// fixtures).
pub fn checksum_tcp(src: [4]u8, dst: [4]u8, segment: []const u8) u16 {
    const len: u16 = @intCast(segment.len);
    var s: u32 = 0;
    s += (@as(u32, src[0]) << 8) | src[1];
    s += (@as(u32, src[2]) << 8) | src[3];
    s += (@as(u32, dst[0]) << 8) | dst[1];
    s += (@as(u32, dst[2]) << 8) | dst[3];
    s += protocol_tcp; // (0x00 << 8) | 6
    s += len;
    return fold(s + sum_words(segment));
}

// ---------------------------------------------------------------------------
// Builders (byte-exact, RFC-shaped; the live gate's fixtures pin them)
// ---------------------------------------------------------------------------

/// Build a TCP segment (20-byte header + payload) into `buf` (must hold
/// >= `tcp_hdr_len + payload.len`): src/dst ports, sequence, ack, data
/// offset 5 (NO options — the honest bound), the flags, the FIXED
/// window, checksum computed over the pseudo-header (src_ip/dst_ip) +
/// the segment (RFC 1071), urgent 0. The payload is truncated honestly
/// at `payload_max`. Returns the segment length (20 + the written
/// payload).
pub fn build_segment(buf: []u8, src_ip: [4]u8, dst_ip: [4]u8, src_port: u16, dst_port: u16, seq: u32, ack: u32, flags: u8, payload: []const u8) usize {
    const plen = @min(payload.len, payload_max);
    const total = tcp_hdr_len + plen;
    @memset(buf[0..total], 0);
    buf[0] = @truncate(src_port >> 8);
    buf[1] = @truncate(src_port);
    buf[2] = @truncate(dst_port >> 8);
    buf[3] = @truncate(dst_port);
    buf[4] = @truncate(seq >> 24);
    buf[5] = @truncate(seq >> 16);
    buf[6] = @truncate(seq >> 8);
    buf[7] = @truncate(seq);
    buf[8] = @truncate(ack >> 24);
    buf[9] = @truncate(ack >> 16);
    buf[10] = @truncate(ack >> 8);
    buf[11] = @truncate(ack);
    buf[12] = 0x50; // data offset 5 (no options) — the honest bound
    buf[13] = flags;
    buf[14] = @truncate(window >> 8);
    buf[15] = @truncate(window);
    // Checksum field at 16..18 — zeroed by the memset during the computation.
    // Urgent pointer at 18..20 = 0 (no urgent data).
    @memcpy(buf[20..total], payload[0..plen]);
    const c = checksum_tcp(src_ip, dst_ip, buf[0..total]);
    buf[16] = @truncate(c >> 8);
    buf[17] = @truncate(c);
    return total;
}

/// Build the FULL Ethernet + IPv4 + TCP frame into `buf` (must hold >=
/// `eth_hdr_len + ipv4_hdr_len + segment.len`): dst MAC (the peer — the
/// caller resolved it), src MAC, ethertype 0x0800, a 20-byte IPv4 header
/// (version 4 / IHL 5, identification 0 — deterministic, total length,
/// TTL 64, protocol 6, header checksum), then the pre-built segment.
/// Returns the frame length (54 + the segment payload).
pub fn build_frame(buf: []u8, own_mac: *const [6]u8, own_ip: [4]u8, dst_mac: [6]u8, dst_ip: [4]u8, segment: []const u8) usize {
    const total = ipv4_hdr_len + segment.len;
    const frame_len = eth_hdr_len + total;
    @memset(buf[0..frame_len], 0);
    @memcpy(buf[0..6], &dst_mac); // dst
    @memcpy(buf[6..12], own_mac); // src
    buf[12] = 0x08;
    buf[13] = 0x00; // ethertype IPv4
    buf[14] = 0x45; // version 4, IHL 5
    buf[16] = @truncate(total >> 8);
    buf[17] = @truncate(total); // total length
    // Identification (18..20) = 0 (deterministic, gate-assertable).
    buf[22] = 64; // TTL
    buf[23] = protocol_tcp;
    @memcpy(buf[26..30], &own_ip); // src
    @memcpy(buf[30..34], &dst_ip); // dst
    // IPv4 header checksum (the field at 24..26 is zeroed by the memset).
    const hc = fold(sum_words(buf[14..34]));
    buf[24] = @truncate(hc >> 8);
    buf[25] = @truncate(hc);
    @memcpy(buf[34 .. 34 + segment.len], segment);
    return frame_len;
}

fn be32(b: []const u8) u32 {
    return (@as(u32, b[0]) << 24) | (@as(u32, b[1]) << 16) | (@as(u32, b[2]) << 8) | b[3];
}

// ---------------------------------------------------------------------------
// The client state machine
// ---------------------------------------------------------------------------

pub var owner_pid: ?u64 = null;

/// Close connection if owned by `pid` (called during process exit).
pub fn close_owner(pid: u64) void {
    if (owner_pid) |p| {
        if (p == pid) {
            if (state == .established or state == .syn_sent or state == .fin_sent) {
                release_conn();
            }
            owner_pid = null;
        }
    }
}

/// Reset the client (tests only — the live kernel never re-initializes).
pub fn reset() void {
    state = .idle;
    is_server = false;
    listen_port = 0;
    owner_pid = null;
    peer_ip = .{ 0, 0, 0, 0 };
    peer_port = 0;
    peer_mac = .{ 0, 0, 0, 0, 0, 0 };
    isn = 0;
    srv_isn = 0;
    snd_una = 0;
    rcv_nxt = 0;
    msg_len = 0;
    ack_pending = false;
    rx_len = 0;
    rx_pending = false;
    tx_pending = false;
    retx_len = 0;
    tx_ticks = 0;
    retx_count = 0;
    syn_sent = 0;
    synack_recv = 0;
    ack_sent = 0;
    data_sent = 0;
    data_recv = 0;
    fin_sent = 0;
    finack_recv = 0;
    rst_sent = 0;
    rst_recv = 0;
    timed_out = 0;
    retransmitted = 0;
    retx_aborted = 0;
    dropped_badsum = 0;
    dropped_malformed = 0;
    now_ticks = 0;
    syn_ticks = 0;
}

/// Enter LISTEN state on a local port (passive open).
pub fn listen(port: u16) void {
    state = .listen;
    listen_port = port;
    is_server = true;
    peer_ip = .{ 0, 0, 0, 0 };
    peer_port = 0;
    peer_mac = .{ 0, 0, 0, 0, 0, 0 };
    isn = 0;
    srv_isn = 0;
    snd_una = 0;
    rcv_nxt = 0;
    msg_len = 0;
    ack_pending = false;
    rx_len = 0;
    rx_pending = false;
    clear_pending();
}

/// Build the next outbound segment into `msg` for THE connection (the
/// fixed src port + the stored peer).
fn build_msg(seq: u32, ack: u32, flags: u8, payload: []const u8) void {
    const local_port = if (is_server) listen_port else default_src_port;
    msg_len = build_segment(&msg, arp.own_ip, peer_ip, local_port, peer_port, seq, ack, flags, payload);
}

/// IDLE -> SYN_SENT: record the peer (the caller resolved the MAC), draw
/// the initial sequence number, and build the SYN into `msg` (seq = the
/// ISN, no ACK — RFC 793 §3.4). The caller transmits `msg[0..msg_len]`,
/// counts `syn_sent`, and advances `snd_una` by 1 (the SYN consumes one
/// sequence number).
pub fn start(peer_ip_in: [4]u8, dst_port: u16, isn_in: u32, peer_mac_in: [6]u8) void {
    is_server = false;
    peer_ip = peer_ip_in;
    peer_port = dst_port;
    peer_mac = peer_mac_in;
    isn = isn_in;
    snd_una = isn_in;
    rcv_nxt = 0;
    srv_isn = 0;
    ack_pending = false;
    rx_pending = false;
    syn_ticks = now_ticks; // the connect clock starts now
    build_msg(isn, 0, flag_syn, &.{});
    state = .syn_sent;
}

/// Seconds since the SYN went out, per the caller-stamped clock.
pub fn elapsed() u64 {
    return now_ticks -| syn_ticks;
}

/// The bounded connect timeout expired (a SYN with no SYN-ACK).
pub fn connect_timed_out() bool {
    return elapsed() >= connect_timeout;
}

/// The honest connect-refuse: release the connection state and fall back
/// to IDLE, counted `timed_out`. The caller (the monitor) prints the
/// refusal; the next `net tcp connect` is a fresh attempt.
pub fn abort_timeout() void {
    release_conn();
    timed_out += 1;
}

/// Release the connection state honestly (the N10 `abort_timeout` shape
/// — no RST, no TX): IDLE (or LISTEN if server), the peer cleared, the pending buffers
/// cleared. Called by the connect refusal, the retransmission abort
/// (card N11), and any death path.
pub fn release_conn() void {
    state = if (is_server) .listen else .idle;
    peer_ip = .{ 0, 0, 0, 0 };
    peer_port = 0;
    peer_mac = .{ 0, 0, 0, 0, 0, 0 };
    ack_pending = false;
    rx_pending = false;
    clear_pending();
}

/// Card N11 (claim 5357): record the just-transmitted sequence-consuming
/// segment (SYN/data/FIN) as the ONE pending segment — a copy of `msg`
/// (the retransmission buffer, bounded `segment_max`), the RTO clock
/// re-stamped, the retransmission count reset. The caller (the monitor)
/// calls it AFTER a successful transmit; a bare ACK or a RST never calls
/// it (they are never retransmitted).
pub fn record_pending() void {
    @memcpy(retx_msg[0..msg_len], msg[0..msg_len]);
    retx_len = msg_len;
    tx_ticks = now_ticks;
    retx_count = 0;
    tx_pending = true;
}

/// Card N11: clear the pending state (an ACK covered the pending
/// segment, or the connection died). The retransmission timer stops.
pub fn clear_pending() void {
    tx_pending = false;
    retx_len = 0;
    retx_count = 0;
}

/// RFC 1982-style sequence comparison: `a` is at or past `b` (treating
/// the u32 wrap). Used for the ACK-clears-pending check — the peer's
/// ACK covers everything the client has sent when it reaches `snd_una`.
fn seq_ge(a: u32, b: u32) bool {
    return (a -% b) < 0x8000_0000;
}

/// Card N11 (claim 5357): the bounded retransmission poll — the shell
/// idle loop calls it after the RX drain (an ACK processed by the drain
/// cleared the pending state — a retransmission NEVER follows an
/// acknowledged segment). One step per poll: if the pending segment's
/// RTO (3 s of guest ticks) has expired and the bound is not exhausted,
/// rebuild `msg` from the pending copy (byte-identical — the same seq,
/// flags, payload, checksum) and count it; if the bound IS exhausted
/// (10 retransmissions), release the connection honestly (`release_conn`
/// — no RST, no TX) and count the abort. Bare ACKs are never pending.
pub fn poll_rto() RtoEvent {
    if (!tx_pending) return .none;
    if (state == .idle or state == .closed) {
        clear_pending(); // the connection died another way — stop the timer
        return .none;
    }
    if (now_ticks -| tx_ticks < rto_ticks) return .none;
    if (retx_count >= retx_max) {
        retx_aborted += 1;
        release_conn();
        return .abort;
    }
    @memcpy(msg[0..retx_len], retx_msg[0..retx_len]);
    msg_len = retx_len;
    retx_count += 1;
    retransmitted += 1;
    tx_ticks = now_ticks; // the RTO clock restarts at each transmission
    return .retransmit;
}

/// Advance the send sequence by the segment's consumption (1 for the SYN
/// and the FIN, the payload length for data, 0 for a bare ACK). The
/// caller calls it after a successful transmit.
pub fn advance_snd(consumed: usize) void {
    snd_una +%= @intCast(consumed);
}

/// ESTABLISHED: build the data segment for `payload` (seq = snd_una, ack
/// = rcv_nxt — every outbound segment after the handshake carries the
/// client's receive state, RFC 793 §3.5). The payload is truncated
/// honestly at `payload_max`.
pub fn build_data_msg(payload: []const u8) void {
    build_msg(snd_una, rcv_nxt, flag_ack, payload);
}

/// ESTABLISHED: build the FIN (seq = snd_una, ack = rcv_nxt, FIN+ACK —
/// the client-driven close, RFC 793 §3.5).
pub fn build_fin_msg() void {
    build_msg(snd_una, rcv_nxt, flag_ack | flag_fin, &.{});
}

/// ESTABLISHED/SYN_SENT: build the RST (seq = snd_una, ack = rcv_nxt,
/// RST+ACK — the client's abort).
pub fn build_rst_msg() void {
    build_msg(snd_una, rcv_nxt, flag_ack | flag_rst, &.{});
}

/// Copy the received payload out of the bounded RX buffer and clear it
/// (the caller — `net tcp recv` — prints it). Returns the payload slice.
pub fn take_rx() []const u8 {
    const p = rx_payload[0..rx_len];
    rx_pending = false;
    rx_len = 0;
    return p;
}

/// Process one received TCP segment (the frame's IPv4 header was ALREADY
/// validated by ipv4.zig — checksum, fragment, dst address). Runs in the
/// RX drain context; builds the client's answer into `msg` and sets
/// `ack_pending` — the transmission is MONITOR-driven on the next `net
/// tcp` (deterministic, never a transmit from the drain context).
pub fn handle_rx(frame: []const u8) Event {
    if (frame.len < frame_min) {
        dropped_malformed += 1;
        return .none;
    }
    const total = (@as(u16, frame[16]) << 8) | frame[17];
    if (total < ipv4_hdr_len + tcp_hdr_len) {
        dropped_malformed += 1;
        return .none;
    }
    const seg_len = @as(usize, total) - ipv4_hdr_len;
    const remaining = frame.len - (eth_hdr_len + ipv4_hdr_len);
    if (seg_len > remaining) {
        dropped_malformed += 1;
        return .none;
    }
    const segment = frame[eth_hdr_len + ipv4_hdr_len .. eth_hdr_len + ipv4_hdr_len + seg_len];
    var src: [4]u8 = undefined;
    @memcpy(&src, frame[26..30]);
    var dst: [4]u8 = undefined;
    @memcpy(&dst, frame[30..34]);
    if (checksum_tcp(src, dst, segment) != 0x0000) {
        dropped_badsum += 1; // a valid segment folds to 0x0000 (RFC 1071)
        return .none;
    }
    const src_port = (@as(u16, segment[0]) << 8) | segment[1];
    const dst_port = (@as(u16, segment[2]) << 8) | segment[3];
    const expected_dst = if (is_server) listen_port else default_src_port;
    if (dst_port != expected_dst) {
        dropped_malformed += 1; // a segment for a port we do not own
        return .none;
    }
    if (state != .listen and src_port != peer_port) {
        dropped_malformed += 1; // not the peer we connected to
        return .none;
    }
    if (segment[12] >> 4 != 5) {
        dropped_malformed += 1; // options — the honest bound (offset != 5)
        return .none;
    }
    const seq = be32(segment[4..8]);
    const ack = be32(segment[8..12]);
    const flags = segment[13];
    const payload = segment[tcp_hdr_len..];
    if (payload.len > payload_max) {
        dropped_malformed += 1; // no reassembly — the honest bound
        return .none;
    }
    switch (state) {
        .idle => {
            dropped_malformed += 1; // a segment with no connection
            return .none;
        },
        .listen => {
            if ((flags & flag_syn) != 0 and (flags & flag_ack) == 0) {
                // Incoming client SYN on listening port
                peer_ip = src;
                peer_port = src_port;
                @memcpy(&peer_mac, frame[6..12]);
                srv_isn = seq;
                rcv_nxt = srv_isn +% 1;
                isn = 0x54321098; // Server ISN
                snd_una = isn;
                build_msg(isn, rcv_nxt, flag_syn | flag_ack, &.{});
                ack_pending = true;
                syn_sent += 1;
                advance_snd(1); // SYN-ACK consumes 1 sequence number
                record_pending();
                state = .syn_received;
                return .synack_recv;
            }
            dropped_malformed += 1;
            return .none;
        },
        .syn_received => {
            if ((flags & flag_rst) != 0) {
                rst_recv += 1;
                clear_pending();
                state = .listen;
                return .rst_recv;
            }
            if ((flags & flag_ack) != 0) {
                if (ack == snd_una) {
                    clear_pending();
                    state = .established;
                    if (payload.len != 0) {
                        @memcpy(rx_payload[0..payload.len], payload);
                        rx_len = payload.len;
                        rx_pending = true;
                        rcv_nxt = seq +% @as(u32, @intCast(payload.len));
                        data_recv += 1;
                        build_msg(snd_una, rcv_nxt, flag_ack, &.{});
                        ack_pending = true;
                        return .data_recv;
                    }
                    return .none;
                }
            }
            dropped_malformed += 1;
            return .none;
        },
        .syn_sent => {
            if ((flags & flag_rst) != 0) {
                rst_recv += 1; // connection refused — the peer RST our SYN
                clear_pending();
                state = .closed;
                return .rst_recv;
            }
            if ((flags & (flag_syn | flag_ack)) != (flag_syn | flag_ack)) {
                dropped_malformed += 1; // not a SYN-ACK
                return .none;
            }
            if (ack != isn +% 1) {
                dropped_malformed += 1; // it does not acknowledge our SYN
                return .none;
            }
            if (payload.len != 0) {
                dropped_malformed += 1; // a SYN-ACK carries no payload
                return .none;
            }
            srv_isn = seq;
            rcv_nxt = srv_isn +% 1;
            state = .established;
            clear_pending(); // the SYN-ACK acknowledges our SYN — the timer stops
            // The handshake ACK (seq = our ISN+1, ack = the server's
            // ISN+1 — the SND/RCV state after the SYN).
            build_msg(isn +% 1, rcv_nxt, flag_ack, &.{});
            ack_pending = true;
            synack_recv += 1;
            return .synack_recv;
        },
        .established => {
            if ((flags & flag_rst) != 0) {
                rst_recv += 1;
                clear_pending(); // the connection died — the timer stops
                state = .closed; // the connection died — the report shows it
                return .rst_recv;
            }
            // Card N11 (claim 5357): ANY accepted segment whose ACK
            // covers everything the client has sent acknowledges the
            // pending segment — the retransmission timer stops (the
            // honest check: an acknowledged segment is never
            // retransmitted).
            if (tx_pending and seq_ge(ack, snd_una)) clear_pending();
            if ((flags & flag_fin) != 0) {
                if ((flags & flag_ack) == 0 or payload.len != 0) {
                    dropped_malformed += 1; // a clean FIN+ACK close only (honest bound)
                    return .none;
                }
                // A server FIN+ACK (the close answer, or the server
                // closing first): count it, ACK it, and stay ESTABLISHED
                // — the caller's `net tcp close` completes the close.
                rcv_nxt = seq +% 1; // the FIN consumes one sequence number
                finack_recv += 1;
                build_msg(snd_una, rcv_nxt, flag_ack, &.{});
                ack_pending = true;
                return .finack_recv;
            }
            if (payload.len != 0) {
                if (rx_pending) {
                    dropped_malformed += 1; // the ONE-slot RX buffer is full (net tcp recv first)
                    return .none;
                }
                @memcpy(rx_payload[0..payload.len], payload);
                rx_len = payload.len;
                rx_pending = true;
                rcv_nxt = seq +% @as(u32, @intCast(payload.len));
                data_recv += 1;
                build_msg(snd_una, rcv_nxt, flag_ack, &.{});
                ack_pending = true;
                return .data_recv;
            }
            // A pure ACK: accepted, ignored (no retransmission machinery).
            return .none;
        },
        .fin_sent => {
            if ((flags & flag_rst) != 0) {
                rst_recv += 1;
                clear_pending();
                state = .closed;
                return .rst_recv;
            }
            if ((flags & (flag_fin | flag_ack)) != (flag_fin | flag_ack)) {
                dropped_malformed += 1; // not the FIN-ACK we are waiting for
                return .none;
            }
            if (payload.len != 0) {
                dropped_malformed += 1;
                return .none;
            }
            rcv_nxt = seq +% 1; // the FIN consumes one sequence number
            finack_recv += 1;
            clear_pending(); // the FIN-ACK acknowledges our FIN — the timer stops
            state = .closed;
            // The final ACK (seq = snd_una — after our FIN — ack =
            // rcv_nxt — after the server's FIN).
            build_msg(snd_una, rcv_nxt, flag_ack, &.{});
            ack_pending = true;
            return .finack_recv;
        },
        .closed => {
            dropped_malformed += 1; // the connection is done
            return .none;
        },
    }
}

// ---------------------------------------------------------------------------
// Host tests — pure logic, byte-exact against the fixtures
// ---------------------------------------------------------------------------

const test_mac = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 }; // the host-set guest MAC
const host_mac = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x02 }; // the host-side MAC
const ip_guest = [4]u8{ 10, 0, 0, 1 };
const ip_host = [4]u8{ 10, 0, 0, 2 };

/// Craft a full TCP frame the way the host responder does (the guest's
/// `build_frame` with a pre-built segment — the fixture shape).
fn craft_frame(own: [4]u8, own_m: [6]u8, peer: [4]u8, peer_m: [6]u8, src_port: u16, dst_port: u16, seq: u32, ack: u32, flags: u8, payload: []const u8) [frame_max]u8 {
    var frame: [frame_max]u8 = undefined;
    var seg: [segment_max]u8 = undefined;
    const seg_len = build_segment(&seg, own, peer, src_port, dst_port, seq, ack, flags, payload);
    const flen = build_frame(&frame, &own_m, own, peer_m, peer, seg[0..seg_len]);
    std.debug.assert(flen <= frame_max);
    return frame;
}

test "tcp: build_segment is byte-exact — the SYN fixture (54-byte frame, 20-byte header)" {
    var seg: [segment_max]u8 = undefined;
    const n = build_segment(&seg, ip_guest, ip_host, default_src_port, 9999, 0x12345678, 0, flag_syn, &.{});
    try std.testing.expectEqual(@as(usize, 20), n);
    try std.testing.expectEqual(@as(u16, 8000), (@as(u16, seg[0]) << 8) | seg[1]);
    try std.testing.expectEqual(@as(u16, 9999), (@as(u16, seg[2]) << 8) | seg[3]);
    // seq = the ISN, big-endian (bytes 4..8).
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34, 0x56, 0x78 }, seg[4..8]);
    // ack = 0 (no ACK in the SYN).
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, seg[8..12]);
    try std.testing.expectEqual(@as(u8, 0x50), seg[12]); // data offset 5 (no options)
    try std.testing.expectEqual(@as(u8, flag_syn), seg[13]); // flags SYN
    try std.testing.expectEqual(@as(u8, 0x10), seg[14]); // window 4096 high
    try std.testing.expectEqual(@as(u8, 0x00), seg[15]);
    // Urgent pointer (18..20) = 0.
    try std.testing.expectEqualSlices(u8, &.{ 0, 0 }, seg[18..20]);
    // The checksum field is NOT zero (computed always — RFC 1071).
    try std.testing.expect(seg[16] != 0 or seg[17] != 0);
    // The checksum verifies (folds to 0x0000) and binds the pseudo-header
    // (a different dst IP yields a different checksum — the sum is
    // commutative in src/dst, so the swap is NOT the binding test).
    try std.testing.expectEqual(@as(u16, 0x0000), checksum_tcp(ip_guest, ip_host, seg[0..n]));
    try std.testing.expect(checksum_tcp(ip_guest, .{ 10, 0, 0, 99 }, seg[0..n]) != 0x0000);
}

test "tcp: build_frame is byte-exact — the full 54-byte SYN frame" {
    var seg: [segment_max]u8 = undefined;
    const seg_len = build_segment(&seg, ip_guest, ip_host, default_src_port, 9999, 0x12345678, 0, flag_syn, &.{});
    var frame: [frame_max]u8 = undefined;
    const n = build_frame(&frame, &test_mac, ip_guest, host_mac, ip_host, seg[0..seg_len]);
    try std.testing.expectEqual(@as(usize, 54), n);
    try std.testing.expectEqualSlices(u8, &host_mac, frame[0..6]); // dst
    try std.testing.expectEqualSlices(u8, &test_mac, frame[6..12]); // src
    try std.testing.expectEqualSlices(u8, &.{ 0x08, 0x00 }, frame[12..14]); // ethertype IPv4
    try std.testing.expectEqual(@as(u8, 0x45), frame[14]); // version 4, IHL 5
    try std.testing.expectEqual(@as(u8, 40), frame[17]); // total length 20 + 20
    try std.testing.expectEqual(@as(u8, 64), frame[22]); // TTL
    try std.testing.expectEqual(@as(u8, 6), frame[23]); // protocol TCP
    try std.testing.expectEqualSlices(u8, &ip_guest, frame[26..30]);
    try std.testing.expectEqualSlices(u8, &ip_host, frame[30..34]);
    // The IPv4 header checksum verifies (folds to 0x0000).
    try std.testing.expectEqual(@as(u16, 0x0000), fold(sum_words(frame[14..34])));
    // The segment rides at 34..54.
    try std.testing.expectEqualSlices(u8, seg[0..seg_len], frame[34 .. 34 + seg_len]);
}

test "tcp: the four-segment lifecycle — SYN -> SYN-ACK -> ACK -> data -> FIN -> FIN-ACK" {
    arp.own_ip = ip_guest;
    defer arp.own_ip = .{ 0, 0, 0, 0 };
    reset();
    defer reset();

    // IDLE -> SYN_SENT: the SYN is built into msg (seq = the ISN).
    start(ip_host, 9999, 0x12345678, host_mac);
    try std.testing.expectEqual(State.syn_sent, state);
    try std.testing.expectEqual(@as(usize, 20), msg_len);
    try std.testing.expectEqual(@as(u8, flag_syn), msg[13]);
    // The caller transmits + advances snd_una by 1 (the SYN consumes one).
    advance_snd(1);
    try std.testing.expectEqual(@as(u32, 0x12345679), snd_una);

    // The server's SYN-ACK: seq = its ISN, ack = our ISN+1.
    const sa = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0xabcdef01, 0x12345679, flag_syn | flag_ack, &.{});
    try std.testing.expectEqual(Event.synack_recv, handle_rx(&sa));
    try std.testing.expectEqual(State.established, state);
    try std.testing.expectEqual(@as(u32, 0xabcdef01), srv_isn);
    try std.testing.expectEqual(@as(u32, 0xabcdef02), rcv_nxt);
    try std.testing.expectEqual(@as(u64, 1), synack_recv);
    // The handshake ACK is built: seq = our ISN+1, ack = rcv_nxt, flags ACK.
    try std.testing.expect(ack_pending);
    try std.testing.expectEqual(@as(u8, flag_ack), msg[13]);
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34, 0x56, 0x79 }, msg[4..8]); // seq
    try std.testing.expectEqualSlices(u8, &.{ 0xab, 0xcd, 0xef, 0x02 }, msg[8..12]); // ack

    // The server's data echo: seq = its ISN+1, ack = our ISN+2 (it acked
    // our handshake ACK), payload "hi".
    const echo = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0xabcdef02, 0x1234567a, flag_ack, "hi");
    try std.testing.expectEqual(Event.data_recv, handle_rx(&echo));
    try std.testing.expectEqual(@as(u64, 1), data_recv);
    try std.testing.expect(rx_pending);
    try std.testing.expectEqualSlices(u8, "hi", rx_payload[0..rx_len]);
    try std.testing.expectEqual(@as(u32, 0xabcdef04), rcv_nxt); // +2 for the payload
    // The ACK for the echo is built (ack = rcv_nxt).
    try std.testing.expect(ack_pending);
    try std.testing.expectEqualSlices(u8, &.{ 0xab, 0xcd, 0xef, 0x04 }, msg[8..12]);
    // The caller reads it.
    try std.testing.expectEqualSlices(u8, "hi", take_rx());
    try std.testing.expect(!rx_pending);

    // The client's close: FIN (seq = snd_una, ack = rcv_nxt). The
    // monitor transmits it and moves to FIN_SENT (the state machine
    // only builds).
    build_fin_msg();
    try std.testing.expectEqual(@as(u8, flag_ack | flag_fin), msg[13]);
    advance_snd(1); // the FIN consumes one sequence number
    state = .fin_sent;

    // The server's FIN-ACK: seq = rcv_nxt (its next), ack = our FIN seq+1.
    const fa = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0xabcdef04, 0x1234567b, flag_ack | flag_fin, &.{});
    try std.testing.expectEqual(Event.finack_recv, handle_rx(&fa));
    try std.testing.expectEqual(State.closed, state);
    try std.testing.expectEqual(@as(u64, 1), finack_recv);
    try std.testing.expectEqual(@as(u32, 0xabcdef05), rcv_nxt); // the FIN consumes one
    // The final ACK is built (ack = rcv_nxt after the server's FIN).
    try std.testing.expect(ack_pending);
    try std.testing.expectEqualSlices(u8, &.{ 0xab, 0xcd, 0xef, 0x05 }, msg[8..12]);
}

test "tcp: malformed + unexpected segments are counted, never assumed away" {
    arp.own_ip = ip_guest;
    defer arp.own_ip = .{ 0, 0, 0, 0 };
    reset();
    defer reset();
    start(ip_host, 9999, 0x11111111, host_mac);

    // A bad checksum -> dropped_badsum.
    var bad = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0x22222222, 0x11111112, flag_syn | flag_ack, &.{});
    bad[40] ^= 0xff; // corrupt the segment (the ack field)
    try std.testing.expectEqual(Event.none, handle_rx(&bad));
    try std.testing.expectEqual(@as(u64, 1), dropped_badsum);

    // A SYN-ACK that does NOT acknowledge our SYN -> dropped_malformed.
    const wrong_ack = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0x22222222, 0x99999999, flag_syn | flag_ack, &.{});
    try std.testing.expectEqual(Event.none, handle_rx(&wrong_ack));
    try std.testing.expectEqual(@as(u64, 1), dropped_malformed);

    // A segment from the WRONG src port -> dropped_malformed.
    const wrong_port = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9998, default_src_port, 0x22222222, 0x11111112, flag_syn | flag_ack, &.{});
    try std.testing.expectEqual(Event.none, handle_rx(&wrong_port));
    try std.testing.expectEqual(@as(u64, 2), dropped_malformed);

    // A segment with options (data offset 6) -> dropped_malformed.
    var opts = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0x22222222, 0x11111112, flag_syn | flag_ack, &.{});
    opts[46] = 0x60; // data offset 6 — must also fix the checksum to land in malformed
    opts[50] = 0;
    opts[51] = 0; // zero the checksum field during the recompute (RFC 1071)
    {
        const seg = opts[34..54];
        const c = checksum_tcp(ip_host, ip_guest, seg);
        opts[50] = @truncate(c >> 8);
        opts[51] = @truncate(c);
    }
    try std.testing.expectEqual(Event.none, handle_rx(&opts));
    try std.testing.expectEqual(@as(u64, 3), dropped_malformed);

    // An oversize payload (65 bytes > payload_max) -> dropped_malformed.
    const big: [65]u8 = .{0x41} ** 65;
    const over = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0x22222222, 0x11111112, flag_syn | flag_ack, &big);
    try std.testing.expectEqual(Event.none, handle_rx(&over));
    try std.testing.expectEqual(@as(u64, 4), dropped_malformed);
    try std.testing.expectEqual(State.syn_sent, state); // unchanged

    // A RST kills the connection.
    const rst = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0x22222222, 0x11111112, flag_ack | flag_rst, &.{});
    try std.testing.expectEqual(Event.rst_recv, handle_rx(&rst));
    try std.testing.expectEqual(@as(u64, 1), rst_recv);
    try std.testing.expectEqual(State.closed, state);
}

test "tcp: the RX buffer holds ONE segment — a second unread segment is dropped" {
    arp.own_ip = ip_guest;
    defer arp.own_ip = .{ 0, 0, 0, 0 };
    reset();
    defer reset();
    start(ip_host, 9999, 1, host_mac);
    // Fast-forward to ESTABLISHED.
    const sa = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0xaaaa0000, 2, flag_syn | flag_ack, &.{});
    try std.testing.expectEqual(Event.synack_recv, handle_rx(&sa));

    const d1 = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0xaaaa0001, 3, flag_ack, "one");
    try std.testing.expectEqual(Event.data_recv, handle_rx(&d1));
    try std.testing.expectEqual(@as(u64, 1), data_recv);
    // The second segment arrives BEFORE `net tcp recv` — dropped (counted).
    const d2 = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0xaaaa0005, 3, flag_ack, "two");
    try std.testing.expectEqual(Event.none, handle_rx(&d2));
    try std.testing.expectEqual(@as(u64, 1), dropped_malformed);
    try std.testing.expectEqualSlices(u8, "one", rx_payload[0..rx_len]); // unchanged
}

test "tcp: the bounded connect timeout — 30 s then an honest refuse" {
    arp.own_ip = ip_guest;
    defer arp.own_ip = .{ 0, 0, 0, 0 };
    reset();
    defer reset();
    start(ip_host, 9999, 0x01020304, host_mac);
    try std.testing.expectEqual(State.syn_sent, state);
    // The clock: syn_ticks stamped at start; elapsed is wall-clock seconds.
    syn_ticks = 100;
    now_ticks = 105;
    try std.testing.expectEqual(@as(u64, 5), elapsed());
    try std.testing.expect(!connect_timed_out());
    now_ticks = 130;
    try std.testing.expectEqual(@as(u64, 30), elapsed());
    try std.testing.expect(connect_timed_out());
    // The honest refuse: back to IDLE, connection state released, counted.
    abort_timeout();
    try std.testing.expectEqual(State.idle, state);
    try std.testing.expectEqual(@as(u64, 1), timed_out);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, &peer_ip);
    try std.testing.expect(!ack_pending);
    // The next connect is a fresh attempt.
    start(ip_host, 9999, 0x0a0b0c0d, host_mac);
    try std.testing.expectEqual(State.syn_sent, state);
}

test "tcp: a server FIN+ACK in ESTABLISHED is ACKed; the caller closes" {
    arp.own_ip = ip_guest;
    defer arp.own_ip = .{ 0, 0, 0, 0 };
    reset();
    defer reset();
    start(ip_host, 9999, 1, host_mac);
    const sa = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0xbbbb0000, 2, flag_syn | flag_ack, &.{});
    try std.testing.expectEqual(Event.synack_recv, handle_rx(&sa));

    // The server closes first: FIN+ACK, no payload.
    const fin = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0xbbbb0001, 3, flag_ack | flag_fin, &.{});
    try std.testing.expectEqual(Event.finack_recv, handle_rx(&fin));
    try std.testing.expectEqual(@as(u64, 1), finack_recv);
    try std.testing.expectEqual(@as(u32, 0xbbbb0002), rcv_nxt);
    try std.testing.expectEqual(State.established, state); // the client still closes
    try std.testing.expect(ack_pending); // the ACK for the FIN is built
    // The caller's `net tcp close` completes the close.
    build_fin_msg();
    try std.testing.expectEqual(@as(u8, flag_ack | flag_fin), msg[13]);
}

test "tcp: a bare SYN (no ACK) in SYN_SENT is malformed" {
    arp.own_ip = ip_guest;
    defer arp.own_ip = .{ 0, 0, 0, 0 };
    reset();
    defer reset();
    start(ip_host, 9999, 7, host_mac);
    const syn = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0xcccc0000, 0, flag_syn, &.{});
    try std.testing.expectEqual(Event.none, handle_rx(&syn));
    try std.testing.expectEqual(@as(u64, 1), dropped_malformed);
    try std.testing.expectEqual(State.syn_sent, state);
}

test "tcp: card N11 — the RTO retransmits the pending SYN byte-exact; the SYN-ACK stops the timer" {
    arp.own_ip = ip_guest;
    defer arp.own_ip = .{ 0, 0, 0, 0 };
    reset();
    defer reset();
    now_ticks = 100;
    start(ip_host, 9999, 0x12345678, host_mac);
    // The caller transmits the SYN and records it pending.
    record_pending();
    try std.testing.expect(tx_pending);
    try std.testing.expectEqual(@as(u64, 0), retx_count);
    const syn0 = msg[0..msg_len];
    // The RTO (3 s) has NOT expired.
    now_ticks = 102;
    try std.testing.expectEqual(RtoEvent.none, poll_rto());
    // At 3 s the RTO fires: the SAME bytes (seq, flags, checksum) rebuild.
    now_ticks = 103;
    try std.testing.expectEqual(RtoEvent.retransmit, poll_rto());
    try std.testing.expectEqual(@as(u64, 1), retransmitted);
    try std.testing.expectEqual(@as(u64, 1), retx_count);
    try std.testing.expectEqualSlices(u8, syn0, msg[0..msg_len]);
    // A second retransmission, byte-identical again.
    now_ticks = 106;
    try std.testing.expectEqual(RtoEvent.retransmit, poll_rto());
    try std.testing.expectEqual(@as(u64, 2), retransmitted);
    try std.testing.expectEqualSlices(u8, syn0, msg[0..msg_len]);
    // The SYN-ACK then lands — it acknowledges our SYN, the timer stops.
    const sa = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0xabcdef01, 0x12345679, flag_syn | flag_ack, &.{});
    try std.testing.expectEqual(Event.synack_recv, handle_rx(&sa));
    try std.testing.expect(!tx_pending);
    now_ticks = 200; // long past the RTO — nothing fires
    try std.testing.expectEqual(RtoEvent.none, poll_rto());
    try std.testing.expectEqual(@as(u64, 2), retransmitted); // unchanged
}

test "tcp: card N11 — a peer ACK covering snd_una clears the pending data; no retransmission" {
    arp.own_ip = ip_guest;
    defer arp.own_ip = .{ 0, 0, 0, 0 };
    reset();
    defer reset();
    now_ticks = 100;
    start(ip_host, 9999, 0x11111111, host_mac);
    advance_snd(1); // the SYN was transmitted
    const sa = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0xaaaa0000, 0x11111112, flag_syn | flag_ack, &.{});
    try std.testing.expectEqual(Event.synack_recv, handle_rx(&sa));
    // The caller sends 2 data bytes: build + transmit + advance + record.
    build_data_msg("hi");
    advance_snd(2);
    record_pending();
    try std.testing.expect(tx_pending);
    // The peer's ACK covers snd_una (0x11111114) — the pending clears.
    const ack = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0xaaaa0001, 0x11111114, flag_ack, &.{});
    try std.testing.expectEqual(Event.none, handle_rx(&ack));
    try std.testing.expect(!tx_pending);
    now_ticks = 500; // long past the RTO — no retransmission
    try std.testing.expectEqual(RtoEvent.none, poll_rto());
    try std.testing.expectEqual(@as(u64, 0), retransmitted);
}

test "tcp: card N11 — an ACK that does NOT cover snd_una leaves the pending data armed" {
    arp.own_ip = ip_guest;
    defer arp.own_ip = .{ 0, 0, 0, 0 };
    reset();
    defer reset();
    now_ticks = 100;
    start(ip_host, 9999, 0x22222222, host_mac);
    advance_snd(1);
    const sa = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0xbbbb0000, 0x22222223, flag_syn | flag_ack, &.{});
    try std.testing.expectEqual(Event.synack_recv, handle_rx(&sa));
    build_data_msg("hello");
    advance_snd(5);
    record_pending();
    // The peer ACKs only up to our ISN+1 (it has NOT seen the data).
    const ack = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0xbbbb0001, 0x22222223, flag_ack, &.{});
    try std.testing.expectEqual(Event.none, handle_rx(&ack));
    try std.testing.expect(tx_pending); // still armed
    // The RTO fires — the pending data is retransmitted byte-exact.
    const data0 = msg[0..msg_len];
    now_ticks = 103;
    try std.testing.expectEqual(RtoEvent.retransmit, poll_rto());
    try std.testing.expectEqualSlices(u8, data0, msg[0..msg_len]);
    try std.testing.expectEqual(@as(u64, 1), retransmitted);
}

test "tcp: card N11 — the retransmission bound aborts the connection honestly" {
    arp.own_ip = ip_guest;
    defer arp.own_ip = .{ 0, 0, 0, 0 };
    reset();
    defer reset();
    now_ticks = 100;
    start(ip_host, 9999, 0x33333333, host_mac);
    advance_snd(1);
    const sa = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0xcccc0000, 0x33333334, flag_syn | flag_ack, &.{});
    try std.testing.expectEqual(Event.synack_recv, handle_rx(&sa));
    build_data_msg("x");
    advance_snd(1);
    record_pending();
    // retx_max retransmissions, one per RTO period.
    var i: u64 = 0;
    while (i < retx_max) : (i += 1) {
        now_ticks += rto_ticks;
        try std.testing.expectEqual(RtoEvent.retransmit, poll_rto());
    }
    try std.testing.expectEqual(@as(u64, retx_max), retransmitted);
    try std.testing.expectEqual(@as(u64, 0), retx_aborted);
    try std.testing.expectEqual(State.established, state); // still alive
    // The NEXT RTO period sees the bound exhausted — the honest abort:
    // the connection is released (no RST, no TX), counted, the peer gone.
    now_ticks += rto_ticks;
    try std.testing.expectEqual(RtoEvent.abort, poll_rto());
    try std.testing.expectEqual(@as(u64, 1), retx_aborted);
    try std.testing.expectEqual(State.idle, state);
    try std.testing.expect(!tx_pending);
    try std.testing.expect(!ack_pending);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, &peer_ip);
    try std.testing.expectEqual(@as(u16, 0), peer_port);
    // The timer stays off.
    now_ticks += rto_ticks;
    try std.testing.expectEqual(RtoEvent.none, poll_rto());
}

test "tcp: card N11 — the pending FIN is retransmitted in FIN_SENT" {
    arp.own_ip = ip_guest;
    defer arp.own_ip = .{ 0, 0, 0, 0 };
    reset();
    defer reset();
    now_ticks = 100;
    start(ip_host, 9999, 0x44444444, host_mac);
    advance_snd(1);
    const sa = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0xdddd0000, 0x44444445, flag_syn | flag_ack, &.{});
    try std.testing.expectEqual(Event.synack_recv, handle_rx(&sa));
    // The caller closes: build the FIN, transmit, advance, record.
    build_fin_msg();
    advance_snd(1);
    state = .fin_sent;
    record_pending();
    const fin0 = msg[0..msg_len];
    try std.testing.expectEqual(@as(u8, flag_ack | flag_fin), msg[13]);
    // The RTO fires — the FIN is retransmitted byte-exact.
    now_ticks = 103;
    try std.testing.expectEqual(RtoEvent.retransmit, poll_rto());
    try std.testing.expectEqual(@as(u64, 1), retransmitted);
    try std.testing.expectEqualSlices(u8, fin0, msg[0..msg_len]);
    // The FIN-ACK then lands — it acknowledges our FIN, the timer stops.
    const fa = craft_frame(ip_host, host_mac, ip_guest, test_mac, 9999, default_src_port, 0xdddd0001, 0x44444446, flag_ack | flag_fin, &.{});
    try std.testing.expectEqual(Event.finack_recv, handle_rx(&fa));
    try std.testing.expect(!tx_pending);
    now_ticks = 200;
    try std.testing.expectEqual(RtoEvent.none, poll_rto());
}

test "tcp: passive open and server handshake (listen -> syn_received -> established -> data -> close)" {
    arp.own_ip = ip_guest;
    defer arp.own_ip = .{ 0, 0, 0, 0 };
    reset();
    defer reset();

    // 1. Enter LISTEN on port 8080
    listen(8080);
    try std.testing.expectEqual(State.listen, state);
    try std.testing.expect(is_server);
    try std.testing.expectEqual(@as(u16, 8080), listen_port);

    // 2. Incoming client SYN from host 10.0.0.2:54321
    const syn_frame = craft_frame(ip_host, host_mac, ip_guest, test_mac, 54321, 8080, 0x10000000, 0, flag_syn, &.{});
    const ev1 = handle_rx(&syn_frame);
    try std.testing.expectEqual(Event.synack_recv, ev1);
    try std.testing.expectEqual(State.syn_received, state);
    try std.testing.expect(ack_pending);
    try std.testing.expectEqualSlices(u8, &ip_host, &peer_ip);
    try std.testing.expectEqual(@as(u16, 54321), peer_port);
    try std.testing.expectEqualSlices(u8, &host_mac, &peer_mac);
    try std.testing.expectEqual(@as(u32, 0x10000001), rcv_nxt);

    // Verify SYN-ACK outbound segment built
    try std.testing.expectEqual(@as(u8, flag_syn | flag_ack), msg[13]);
    try std.testing.expectEqualSlices(u8, &.{ 0x10, 0x00, 0x00, 0x01 }, msg[8..12]); // ack = client ISN+1

    // 3. Client sends ACK for our SYN-ACK
    const ack_frame = craft_frame(ip_host, host_mac, ip_guest, test_mac, 54321, 8080, 0x10000001, snd_una, flag_ack, &.{});
    const ev2 = handle_rx(&ack_frame);
    try std.testing.expectEqual(Event.none, ev2);
    try std.testing.expectEqual(State.established, state);

    // 4. Client sends HTTP GET request payload
    const get_payload = "GET / HTTP/1.1\r\n\r\n";
    const data_frame = craft_frame(ip_host, host_mac, ip_guest, test_mac, 54321, 8080, 0x10000001, snd_una, flag_ack, get_payload);
    const ev3 = handle_rx(&data_frame);
    try std.testing.expectEqual(Event.data_recv, ev3);
    try std.testing.expect(rx_pending);
    try std.testing.expectEqualStrings(get_payload, take_rx());

    // 5. Server sends response and releases connection back to LISTEN
    release_conn();
    try std.testing.expectEqual(State.listen, state);
    try std.testing.expectEqual(@as(u16, 0), peer_port);
}
