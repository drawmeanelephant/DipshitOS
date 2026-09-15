//! Certificate chain validation (card TLS13-C4): path building to a configured
//! trust anchor, then RFC 5280 §6.1 checks at every step, as TLS 1.3 needs
//! them. Verification is against a hostname and an injected wall clock, so the
//! same code path proves the valid case and the expired / not-yet-valid cases
//! without needing faketime-generated fixtures.
//!
//! The checks, in order: find a path from the leaf to a root in the trust
//! store (intermediates may arrive unordered or missing the root); verify each
//! certificate's signature over the child's `tbsCertificate`; check the
//! validity window of every certificate; require basicConstraints cA=TRUE on
//! every signer; enforce pathLenConstraint; require keyUsage keyCertSign on
//! intermediates; require EKU serverAuth on the leaf (absent = unrestricted);
//! enforce DNS nameConstraints permitted/excluded subtrees; reject any unknown
//! critical extension; reject signature algorithms TLS 1.3 does not permit;
//! and finally match the leaf's identity to `host`.
//!
//! Anything that does not pass fails closed to a specific `Result` code rather
//! than a generic failure.

const std = @import("std");
const der = @import("der.zig");
const x509 = @import("x509.zig");
const rsa = @import("rsa.zig");
const ecdsa = @import("ecdsa.zig");
const identity = @import("identity.zig");
const trust_store = @import("trust_store.zig");
const crypto = @import("crypto");

pub const max_path = 8;
pub const max_intermediates = 16;

pub const Result = enum {
    valid,
    parse_error,
    no_path_to_root,
    signature_verification_failed,
    expired,
    not_yet_valid,
    not_a_ca,
    path_length_exceeded,
    key_usage_missing_key_cert_sign,
    eku_not_server_auth,
    unknown_critical_extension,
    unsupported_signature_algorithm,
    name_constraint_violation,
    hostname_mismatch,
};

/// Is `sig_alg` one TLS 1.3 permits for certificates (RFC 8446 §4.4.2.2)?
fn sigAlgAllowed(alg: x509.SigAlg) bool {
    return switch (alg) {
        .rsa_pkcs1_sha256,
        .rsa_pkcs1_sha384,
        .rsa_pkcs1_sha512,
        .rsa_pss_rsae,
        .ecdsa_sha256,
        .ecdsa_sha384,
        .ed25519,
        => true,
        else => false,
    };
}

fn ecdsaVerify(cert: *const x509.Cert, issuer: *const x509.Cert) bool {
    if (issuer.key.kind != .ec) return false;
    const point = issuer.key.point;
    if (point.len < 1 or point[0] != 0x04) return false;
    const flen = (point.len - 1) / 2;
    const qx = point[1 .. 1 + flen];
    const qy = point[1 + flen ..];

    var r = der.Reader.init(cert.signature);
    const seq = r.expect(der.tag.sequence) catch return false;
    if (!r.atEnd()) return false;
    var s = der.Reader.init(seq.content);
    const ri = s.expect(der.tag.integer) catch return false;
    const si = s.expect(der.tag.integer) catch return false;
    if (!s.atEnd()) return false;
    const rb = der.integer(ri) catch return false;
    const sb = der.integer(si) catch return false;

    var z: [64]u8 = undefined;
    const curve: ecdsa.Curve = switch (cert.sig_alg) {
        .ecdsa_sha256 => blk: {
            crypto.sha256.sha256(z[0..32], cert.tbs);
            break :blk ecdsa.curveP256();
        },
        .ecdsa_sha384 => blk: {
            crypto.sha384.sha384(z[0..48], cert.tbs);
            break :blk ecdsa.curveP384();
        },
        else => return false,
    };
    const zlen: usize = if (cert.sig_alg == .ecdsa_sha256) 32 else 48;
    return curve.verify(qx, qy, rb, sb, z[0..zlen]);
}

noinline fn verifyCertSignature(cert: *const x509.Cert, issuer: *const x509.Cert) bool {
    return switch (cert.sig_alg) {
        .rsa_pkcs1_sha256 => issuer.key.kind == .rsa and rsa.verifyPkcs1(issuer.key.rsa_modulus, issuer.key.rsa_exponent, .sha256, cert.tbs, cert.signature),
        .rsa_pkcs1_sha384 => issuer.key.kind == .rsa and rsa.verifyPkcs1(issuer.key.rsa_modulus, issuer.key.rsa_exponent, .sha384, cert.tbs, cert.signature),
        .rsa_pkcs1_sha512 => issuer.key.kind == .rsa and rsa.verifyPkcs1(issuer.key.rsa_modulus, issuer.key.rsa_exponent, .sha512, cert.tbs, cert.signature),
        // RSASSA-PSS: the hash is carried in the params, which the parser does
        // not read; SHA-256 is the mandatory default and the common real case.
        .rsa_pss_rsae => issuer.key.kind == .rsa and rsa.verifyPss(issuer.key.rsa_modulus, issuer.key.rsa_exponent, .sha256, cert.tbs, cert.signature),
        .ecdsa_sha256, .ecdsa_sha384 => ecdsaVerify(cert, issuer),
        .ed25519 => blk: {
            if (issuer.key.kind != .ed25519 or cert.signature.len != 64 or issuer.key.point.len != 32) break :blk false;
            const sig: *const [64]u8 = @ptrCast(cert.signature.ptr);
            const pk: *const [32]u8 = @ptrCast(issuer.key.point.ptr);
            break :blk crypto.ed25519.verify(sig, cert.tbs, pk);
        },
        else => false,
    };
}

/// DNS name-constraint subtree match: ".example.com" matches "example.com" and
/// any single-level-or-deeper subdomain.
fn matchSubtree(base: []const u8, host: []const u8) bool {
    if (base.len == 0 or host.len == 0) return false;
    const b = if (base[0] == '.') base[1..] else base;
    if (std.ascii.eqlIgnoreCase(b, host)) return true;
    if (host.len <= b.len + 1) return false;
    const cut = host.len - b.len - 1;
    if (host[cut] != '.') return false;
    return std.ascii.eqlIgnoreCase(host[cut + 1 ..], b);
}

fn checkNameConstraints(leaf: *const x509.Cert, ca: *const x509.Cert) bool {
    if (!ca.has_name_constraints) return true;
    for (leaf.san[0..leaf.san_len]) |g| {
        const name = switch (g) {
            .dns => |d| d,
            .ip => continue,
        };
        // Every DNS name must satisfy each permitted subtree...
        if (ca.nc_permitted_dns_len != 0) {
            var ok = false;
            for (ca.nc_permitted_dns[0..ca.nc_permitted_dns_len]) |p| {
                if (matchSubtree(p, name)) {
                    ok = true;
                    break;
                }
            }
            if (!ok) return false;
        }
        // ...and must not satisfy any excluded subtree.
        for (ca.nc_excluded_dns[0..ca.nc_excluded_dns_len]) |e| {
            if (matchSubtree(e, name)) return false;
        }
    }
    return true;
}

/// Validate `leaf_der` against `store`, optionally through `intermediates`,
/// for `host` at wall-clock time `now`. Returns a specific failure code.
pub fn validate(
    leaf_der: []const u8,
    intermediates: []const []const u8,
    store: anytype,
    host: []const u8,
    now: i64,
) Result {
    var leaf: x509.Cert = .{};
    x509.Cert.parse(leaf_der, &leaf) catch return .parse_error;

    var parsed_inter: [max_intermediates]x509.Cert = undefined;
    var inter_len: usize = 0;
    for (intermediates) |d| {
        if (inter_len >= max_intermediates) break;
        x509.Cert.parse(d, &parsed_inter[inter_len]) catch return .parse_error;
        inter_len += 1;
    }

    // --- path building ---
    var path: [max_path]x509.Cert = undefined;
    path[0] = leaf;
    var n: usize = 1;
    var current: x509.Cert = leaf;
    // The path is only acceptable if it terminates at a configured trust
    // anchor. Without this, a self-issued certificate that the server also
    // sends as its own "chain" matches itself as its issuer and the walk
    // never has to reach a root at all.
    var reached_anchor = false;
    while (n < max_path) {
        if (store.findIssuer(current.issuer_raw)) |root| {
            path[n] = root.*;
            n += 1;
            reached_anchor = true;
            break;
        }
        var found = false;
        for (parsed_inter[0..inter_len]) |*ic| {
            if (std.mem.eql(u8, ic.subject_raw, current.issuer_raw)) {
                path[n] = ic.*;
                n += 1;
                current = ic.*;
                found = true;
                break;
            }
        }
        if (!found) return .no_path_to_root;
    }
    if (!reached_anchor) return .no_path_to_root;

    // --- per-step checks, leaf (0) through the cert below the root ---
    var i: usize = 0;
    while (i + 1 < n) : (i += 1) {
        const c = &path[i];
        const iss = &path[i + 1];
        if (!sigAlgAllowed(c.sig_alg)) return .unsupported_signature_algorithm;
        if (!verifyCertSignature(c, iss)) return .signature_verification_failed;
        if (now < c.not_before) return .not_yet_valid;
        if (now > c.not_after) return .expired;
        if (c.hasUnknownCritical()) return .unknown_critical_extension;

        // The signer must be a CA, with keyCertSign, and honour pathLen.
        if (!iss.has_basic_constraints or !iss.is_ca) return .not_a_ca;
        if (iss.has_key_usage and iss.key_usage & x509.ku.key_cert_sign == 0) return .key_usage_missing_key_cert_sign;
        if (iss.path_len) |pl| {
            if (i > pl) return .path_length_exceeded; // i CA certs below the signer
        }
        // Name constraints on the signer bind the leaf.
        if (!checkNameConstraints(&path[0], iss)) return .name_constraint_violation;
    }

    // --- root's own window and criticality ---
    const root = &path[n - 1];
    if (now < root.not_before) return .not_yet_valid;
    if (now > root.not_after) return .expired;
    if (root.hasUnknownCritical()) return .unknown_critical_extension;

    // --- leaf identity ---
    if (!path[0].isServerCertEkuOk()) return .eku_not_server_auth;
    if (!identity.ok(identity.verify(&path[0], host))) return .hostname_mismatch;

    return .valid;
}

// ---------------------------------------------------------------------------
const vectors = @import("x509_vectors.zig");

fn hexToBytes(out: []u8, s: []const u8) []u8 {
    const n = s.len / 2;
    _ = std.fmt.hexToBytes(out[0..n], s) catch unreachable;
    return out[0..n];
}

fn fixture(name: []const u8) []const u8 {
    return vectors.byName(name).der_hex;
}

fn validateNamed(store: anytype, leaf: []const u8, inters: []const []const u8, host: []const u8, now: i64) Result {
    var derbuf: [8192]u8 = undefined;
    const leaf_der = hexToBytes(&derbuf, leaf);
    var ibuf: [4][8192]u8 = undefined;
    var inter_der: [4][]const u8 = undefined;
    var n: usize = 0;
    for (inters) |name| {
        if (n >= 4) break;
        inter_der[n] = hexToBytes(&ibuf[n], name);
        n += 1;
    }
    return validate(leaf_der, inter_der[0..n], store, host, now);
}

test "validate: a leaf -> intermediate -> root chain validates for the right host" {
    var store = trust_store.TrustStore.init();
    var rb: [8192]u8 = undefined;
    store.setVersion("fixtures-v1");
    try store.addRoot(hexToBytes(&rb, fixture("root")));
    try std.testing.expectEqual(@as(usize, 1), store.rootCount());
    try std.testing.expectEqualStrings("fixtures-v1", store.versionString());

    // now between leaf-ec (825 days from generation) and everything's validity.
    const now: i64 = vectors.byName("leaf-ec").not_before + 100;

    try std.testing.expectEqual(Result.valid, validateNamed(&store, fixture("leaf-ec"), &.{fixture("inter")}, "leaf.example.com", now));
    try std.testing.expectEqual(Result.valid, validateNamed(&store, fixture("leaf-rsa"), &.{fixture("inter")}, "rsa.example.com", now));
    // Wildcard SAN still resolves.
    try std.testing.expectEqual(Result.valid, validateNamed(&store, fixture("leaf-ec"), &.{fixture("inter")}, "a.wild.example.com", now));
    // Unordered / duplicate-free intermediates: the served chain may drop the root.
    try std.testing.expectEqual(Result.valid, validateNamed(&store, fixture("leaf-ec"), &.{ fixture("inter"), fixture("root") }, "leaf.example.com", now));
}

test "validate: hostname, validity, and missing-intermediate all fail closed" {
    var store = trust_store.TrustStore.init();
    var rb: [8192]u8 = undefined;
    try store.addRoot(hexToBytes(&rb, fixture("root")));
    const leaf_ec = vectors.byName("leaf-ec");

    try std.testing.expectEqual(Result.hostname_mismatch, validateNamed(&store, fixture("leaf-ec"), &.{fixture("inter")}, "wrong.example.com", leaf_ec.not_before + 100));
    try std.testing.expectEqual(Result.not_yet_valid, validateNamed(&store, fixture("leaf-ec"), &.{fixture("inter")}, "leaf.example.com", leaf_ec.not_before - 1000));
    try std.testing.expectEqual(Result.expired, validateNamed(&store, fixture("leaf-ec"), &.{fixture("inter")}, "leaf.example.com", leaf_ec.not_after + 1000));
    // The intermediate is missing and no root matches the leaf's issuer.
    try std.testing.expectEqual(Result.no_path_to_root, validateNamed(&store, fixture("leaf-ec"), &.{}, "leaf.example.com", leaf_ec.not_before + 100));
    // A trust anchor used as its own leaf builds a trivial path, then fails on
    // identity (its CN is a CA name, not the requested host).
    try std.testing.expectEqual(Result.hostname_mismatch, validateNamed(&store, fixture("root"), &.{}, "anything.example.com", leaf_ec.not_before + 100));
}

test "validate: unknown critical extension, IP SAN, and CN fallback" {
    var store = trust_store.TrustStore.init();
    var rb: [8192]u8 = undefined;
    try store.addRoot(hexToBytes(&rb, fixture("root")));
    const now = vectors.byName("leaf-ec").not_before + 100;

    // The unknown CRITICAL extension in the leaf must fail the chain.
    try std.testing.expectEqual(Result.unknown_critical_extension, validateNamed(&store, fixture("leaf-unknowncrit"), &.{fixture("inter")}, "unknown.example.com", now));
    // An iPAddress SAN leaf matches only its IP literal.
    try std.testing.expectEqual(Result.valid, validateNamed(&store, fixture("leaf-ip"), &.{fixture("inter")}, "127.0.0.1", now));
    try std.testing.expectEqual(Result.hostname_mismatch, validateNamed(&store, fixture("leaf-ip"), &.{fixture("inter")}, "ip.example.com", now));
    // CN-only leaf: the CN is a *reported* fallback, and ok() refuses it by
    // default, so the chain fails closed on identity.
    try std.testing.expectEqual(Result.hostname_mismatch, validateNamed(&store, fixture("leaf-nosan"), &.{fixture("inter")}, "cnonly.example.com", now));
}

test "validate: name constraints are enforced on the leaf's DNS names" {
    // ca-nc is a CA with permitted .example.com, excluded .evil.example.com.
    // Its leaf (leaf-nc, SAN nc.example.com) validates; a leaf from outside the
    // subtree (leaf-ec, SAN leaf.example.com) also falls inside .example.com,
    // so it is permitted too — the excluded subtree is what a real attack uses.
    var store = trust_store.TrustStore.init();
    var rb: [8192]u8 = undefined;
    try store.addRoot(hexToBytes(&rb, fixture("root")));
    try store.addRoot(hexToBytes(&rb, fixture("ca-nc")));
    const now = vectors.byName("leaf-nc").not_before + 100;

    try std.testing.expectEqual(Result.valid, validateNamed(&store, fixture("leaf-nc"), &.{fixture("ca-nc")}, "nc.example.com", now));
    // A leaf inside the EXCLUDED subtree is refused.
    try std.testing.expectEqual(Result.name_constraint_violation, validateNamed(&store, fixture("leaf-ncevil"), &.{fixture("ca-nc")}, "evil.example.com", now));
    // A leaf outside the PERMITTED subtree is refused.
    try std.testing.expectEqual(Result.name_constraint_violation, validateNamed(&store, fixture("leaf-ncother"), &.{fixture("ca-nc")}, "other.com", now));
}

test "validate: a self-issued certificate cannot be its own trust anchor" {
    // The server may send a self-signed certificate as its own chain. It must
    // still fail: the walk has to terminate at an anchor in the store, and a
    // certificate that matches itself never does.
    var empty = trust_store.TrustStore.init();
    const now = vectors.byName("root").not_before + 100;
    try std.testing.expectEqual(Result.no_path_to_root, validateNamed(&empty, fixture("root"), &.{fixture("root")}, "anything.example.com", now));
    try std.testing.expectEqual(Result.no_path_to_root, validateNamed(&empty, fixture("leaf-ec"), &.{fixture("leaf-ec")}, "leaf.example.com", now));
}

test "validate: trust store mutation is reflected immediately" {
    var store = trust_store.TrustStore.init();
    var rb: [8192]u8 = undefined;
    const root_der = hexToBytes(&rb, fixture("root"));
    try store.addRoot(root_der);
    const now = vectors.byName("leaf-ec").not_before + 100;

    try std.testing.expectEqual(Result.valid, validateNamed(&store, fixture("leaf-ec"), &.{fixture("inter")}, "leaf.example.com", now));

    try std.testing.expect(store.removeRoot(root_der));
    try std.testing.expectEqual(@as(usize, 0), store.rootCount());
    try std.testing.expectEqual(Result.no_path_to_root, validateNamed(&store, fixture("leaf-ec"), &.{fixture("inter")}, "leaf.example.com", now));

    // A non-CA root is refused at injection.
    try std.testing.expectError(trust_store.TrustStore.Error.BadRoot, store.addRoot(hexToBytes(&rb, fixture("leaf-ec"))));
}
