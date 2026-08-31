//! M33 SB1 (claim 7418, ADR 0016 D2): shared-region CAPABILITY POLICY, frozen
//! before the capability is built.
//!
//! This module is PURE POLICY — it makes the D2 security/capability DECISIONS
//! (who may read whose surface, read-only-vs-writable grant, who gets revoked
//! on teardown, and when a region is freed) as deterministic, host-testable
//! functions with NO effect on the MMU or any page table. It is the frozen,
//! runnable spec that SB2 (claim next) implements into `sys_mmap`: SB2 wires
//! these decisions to actual `mmu.map_user_cow_page` leaves under two EL0
//! roots (owner writable, WM read-only) and to `unmap_user_page` on teardown.
//!
//! The capability model (ADR 0016 D2):
//!   - Requestor-vs-owner. A shared surface is created and OWNED by the app
//!     that renders into it; only that app's root ever holds a WRITABLE leaf.
//!   - Read-only for compositors. The registered WM server (`wm_peer`) maps
//!     the surface EL0-RO (`sw_cow`, M29). A COW fault there is a kernel
//!     error, never a silent copy (D4).
//!   - Revocation on close/teardown. When the owner's window closes or the
//!     owner exits, EVERY peer's RO leaf is revoked (unmapped) and the region
//!     descriptor is dropped when the refcount reaches zero. No peer retains
//!     access past that point.
//!   - Trust boundary. The WM is the only peer trusted with another app's
//!     surface read today; every other requestor is re-authorized per call
//!     and gets read-only at most — never the owner's writable view.
//!
//! No libc, no POSIX, no allocation — a fixed BSS descriptor table sized by
//! `max_shared_regions`, in keeping with the ADR 0005/0013 bounded-BSS rule.

const std = @import("std");

/// Bound on concurrently-live shared regions (the fixed `SharedRegion` BSS
/// array). Deliberately small — seam-B migrates apps one at a time (the WMS7
/// mailbox re-point lever), so a handful of live surfaces covers the first
/// stretching pass. SB2 sizes the actual array from this constant.
pub const max_shared_regions: usize = 8;

/// The grant outcome the D2 rule computes before any leaf is touched. SB2 maps
/// real pages only for `.grant` results.
pub const Grant = union(enum) {
    /// Grant the requestor a READ-ONLY (`sw_cow`) leaf for this region.
    grant,
    /// Refuse the request: beat the region table (region already at max).
    capacity,
    /// Refuse the request: the requestor is not the owner and not an
    /// authorized reader (not the WM, or no WM registered).
    not_authorized,
    /// Refuse the request: the region/surface no longer exists.
    gone,
    /// Driver-only guard: a requestor may never ask for a WRITABLE peer view.
    /// The owner's own writable map is NOT a peer request — it is the region's
    /// creation-side map and lives outside this rule (SB2 keeps it at open).
    writable_refused,
};

/// A fixed descriptor row (the ADR 0016 D1 "small fixed SharedRegion table"
/// shape, keyed by a kernel-issued integer handle). SB2 owns the physical
/// va/pa set; this policy row owns the capability identity — owner, refcount,
/// and the WM peer grant. The `pages`/`va` fields are reserved placeholders
/// for SB2's mmap wiring and are NOT set by this policy module (kept 0).
pub const SharedRegion = struct {
    in_use: bool,
    handle: u32,
    owner_pid: u64,
    /// Read references (the WM and any re-authorized readers). The OWNER is
    /// NOT counted here — the owner's writable map is the region's creation
    /// side and is torn down with the owner's own teardown, not this refcount.
    refcount: u16,
    /// Whether the peer WM server holds the current read grant for this region.
    wm_granted: bool,

    /// -reserved for SB2- mmap wiring (always 0 in this policy module).
    _pages: u32,
    _va: u64,
};

/// The module-level fixed table (BSS). Reset explicitly; no hidden global
/// initialization order dependency.
var regions: [max_shared_regions]SharedRegion = undefined;
var next_handle: u32 = 1;

/// Reinitialize the table (host tests + a fresh boot), zeroed and empty.
pub fn reset() void {
    for (&regions) |*r| {
        r.in_use = false;
        r.handle = 0;
        r.owner_pid = 0;
        r.refcount = 0;
        r.wm_granted = false;
        r._pages = 0;
        r._va = 0;
    }
    next_handle = 1;
}

/// Create a shared surface owned by `owner_pid`, returning its handle (the D2
/// requestor-vs-owner start: the surface only exists once an app claims it).
/// Returns 0 when the table is full (capacity). WB owner mapping is SB2's job
/// at open — this only reserves the capability identity.
pub fn create(owner_pid: u64) u32 {
    for (&regions) |*r| {
        if (!r.in_use) {
            r.in_use = true;
            r.handle = next_handle;
            next_handle +%= 1;
            r.owner_pid = owner_pid;
            r.refcount = 0;
            r.wm_granted = false;
            return r.handle;
        }
    }
    return 0; // capacity — the region table is full
}

/// The D2 grant rule for reading a shared surface. Pure decision — no MMU
/// effect. `wm_peer` is the registered WM's pid (0 = none registered).
///
/// Returns:
///   - `.grant`          → the requestor may hold a READ-ONLY leaf.
///   - `.writable_refused` → a peer asked for a WRITABLE view (never allowed).
///   - `.not_authorized` → the requestor is not the owner and not an
///                         authorized reader (not `wm_peer`).
///   - `.gone`           → `handle` names no live region.
pub fn authorize_read(
    requestor_pid: u64,
    handle: u32,
    want_writable: bool,
    wm_peer: u64,
) Grant {
    const r = find(handle) orelse return .gone;
    // A peer may never hold a writable view (D2 read-only-for-compositors).
    if (want_writable) return .writable_refused;
    // The owner is always the creator; a read of one's own is granted (SB2
    // keeps it; policy approves it).
    if (requestor_pid == r.owner_pid) return .grant;
    // Only the registered WM may read another app's surface, and only when a
    // WM is registered (seat exists). Every other requestor is refused.
    if (wm_peer != 0 and requestor_pid == wm_peer) return .grant;
    return .not_authorized;
}

/// Record a granted RO read reference. Returns true on success; false if the
/// region is gone or the refcount is already at its u16 bound. The caller
/// (SB2) pre-gates through `authorize_read`; this only bookkeeps.
pub fn grant_read(handle: u32) bool {
    const r = find(handle) orelse return false;
    if (!r.in_use) return false;
    if (r.refcount == std.math.maxInt(u16)) return false;
    r.refcount +%= 1;
    r.wm_granted = true;
    return true;
}

/// Drop one RO read reference (the owner is NOT counted in `refcount`).
pub fn drop_read(handle: u32) void {
    const r = find(handle) orelse return;
    if (r.refcount > 0) {
        r.refcount -= 1;
        if (r.refcount == 0) r.wm_granted = false;
    }
}

/// Revoke the OWNER: clear the region entirely (the D2 revocation-on-teardown
/// rule). Every peer RO leaf goes away with the owner (SB2 unmaps them here),
/// and the descriptor is freed. Returns the number of read references that
/// were revoked, so a live gate can assert peers were dropped.
pub fn drop_owner(handle: u32) u32 {
    const r = find(handle) orelse return 0;
    if (!r.in_use) return 0;
    const revoked = @as(u32, r.refcount);
    r.in_use = false;
    r.refcount = 0;
    r.wm_granted = false;
    r.owner_pid = 0;
    r.handle = 0;
    return revoked;
}

/// How many read references a live region currently holds (observability; SB2
/// reports it pre-revoke so a gate can assert the specified N peers were dropped).
pub fn read_count(handle: u32) u32 {
    const r = find(handle) orelse return 0;
    if (!r.in_use) return 0;
    return r.refcount;
}

fn find(handle: u32) ?*SharedRegion {
    for (&regions) |*r| {
        if (r.in_use and r.handle == handle) return r;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Host tests — the D2 rule, pinned before the capability exists.
// ---------------------------------------------------------------------------

test "shared_region: capacity bound" {
    reset();
    var n: u32 = 0;
    while (n < max_shared_regions) : (n += 1) {
        const h = create(1000 + n);
        try std.testing.expect(h != 0);
    }
    try std.testing.expect(create(2000) == 0);
}

test "shared_region: owner always granted; a peer is WM-only" {
    reset();
    const owner: u64 = 42;
    const wm: u64 = 7;
    const stranger: u64 = 99;
    const h = create(owner);
    try std.testing.expect(h != 0);

    try std.testing.expect(authorize_read(owner, h, false, wm) == .grant);
    try std.testing.expect(authorize_read(wm, h, true, wm) == .writable_refused);
    try std.testing.expect(authorize_read(wm, h, false, wm) == .grant);
    try std.testing.expect(authorize_read(stranger, h, false, wm) == .not_authorized);
}

test "shared_region: no WM registered means no peer reads at all" {
    reset();
    const owner: u64 = 42;
    const h = create(owner);
    try std.testing.expect(h != 0);
    const wouldbe_wm: u64 = 7;
    try std.testing.expect(authorize_read(wouldbe_wm, h, false, 0) == .not_authorized);
    try std.testing.expect(authorize_read(owner, h, false, 0) == .grant);
}

test "shared_region: grant_read / drop_read maintain the read refcount" {
    reset();
    const owner: u64 = 42;
    const wm: u64 = 7;
    const h = create(owner);
    try std.testing.expect(h != 0);
    try std.testing.expect(authorize_read(wm, h, false, wm) == .grant);
    try std.testing.expect(grant_read(h));
    try std.testing.expect(grant_read(h));
    try std.testing.expect(read_count(h) == 2);
    drop_read(h);
    try std.testing.expect(read_count(h) == 1);
    drop_read(h);
    try std.testing.expect(read_count(h) == 0);
}

test "shared_region: teardown revokes every peer and frees the descriptor" {
    reset();
    const owner: u64 = 42;
    const wm: u64 = 7;
    const h = create(owner);
    try std.testing.expect(h != 0);
    try std.testing.expect(authorize_read(wm, h, false, wm) == .grant);
    try std.testing.expect(grant_read(h));
    try std.testing.expect(read_count(h) == 1);

    const revoked = drop_owner(h);
    try std.testing.expect(revoked == 1);
    try std.testing.expect(authorize_read(wm, h, false, wm) == .gone);
    try std.testing.expect(read_count(h) == 0);
    drop_read(h); // no-op on a dead region
}

test "shared_region: stale handle after teardown cannot re-grant old peers" {
    reset();
    const owner: u64 = 42;
    const wm: u64 = 7;
    const h = create(owner);
    try std.testing.expect(h != 0);
    try std.testing.expect(authorize_read(wm, h, false, wm) == .grant);
    try std.testing.expect(grant_read(h));
    _ = drop_owner(h);
    try std.testing.expect(grant_read(h) == false);

    // A NEW region after reset is independent of any prior grant state.
    reset();
    const fresh = create(owner);
    try std.testing.expect(fresh != 0);
    try std.testing.expect(read_count(fresh) == 0);
    try std.testing.expect(authorize_read(wm, fresh, false, wm) == .grant);
}
