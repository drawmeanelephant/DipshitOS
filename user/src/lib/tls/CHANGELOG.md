# TLS 1.3 client — changelog

## v0.1.0-tls13 — 2026-09-14

First release of the in-tree TLS 1.3 client (ADR 0029). Cards #1262, #1264,
#1265, #1266, #1267; documentation and rollback are #1268.

### Added

- **crypto**: HKDF (RFC 5869), SHA-384 + HMAC-SHA384 (FIPS 180-4), AES-128/256
  (FIPS 197), AES-GCM (NIST SP 800-38D), Montgomery bigint with
  RSASSA-PKCS1-v1_5 / PSS (RFC 8017) and ECDSA P-256/P-384 (FIPS 186-4).
- **tls**: `keyschedule.zig` (RFC 8446 §7.1), `record.zig` (§5), `der.zig`,
  `pem.zig`, `x509.zig`, `identity.zig`, `trust_store.zig`, `validate.zig`,
  `handshake.zig` (the named state machine), `client.zig` (the 1-RTT driver).
- **interop**: `interop_driver.zig`, `interop/ledger.jsonl`, and the two
  runner scripts under `vectors/`.

### Verified

- 3548 host tests pass (`zig build test`), 101 of them new.
- Live interop: 4 independent peer implementations (openssl s_server ECDSA,
  openssl s_server RSA with an intermediate, gnutls-serv, Go crypto/tls) and 8
  public endpoints complete a handshake and exchange application data;
  5 negative endpoints fail closed.

### Known limitations

See `INTEGRATION.md`. The load-bearing ones: TLS_AES_128_GCM_SHA256 + x25519
only; no revocation checking; no AIA fetching (a server that omits its
intermediate chain fails path building); table-based AES, so not cache-timing
constant-time.

### Not yet wired

No guest consumer. `fetch.zig` and `download.zig` remain plain-HTTP. The client
is host-verified end to end; the guest path lands with its consumer card.

---

## Disabling the client (the pin)

The TLS library is not linked into any guest binary, so disabling it is a build
flag rather than a code change:

```
zig build test -Dtls_client=false
```

This drops the 11 TLS roots from `unit_test_sources` and nothing else.

### Rollback exercise — performed 2026-09-14, result recorded

| Build | Result |
|---|---|
| `zig build test` (default, TLS client on) | `194/194 steps succeeded; 3548/3548 tests passed` |
| `zig build test -Dtls_client=false` (pin engaged) | `172/172 steps succeeded; 3447/3447 tests passed` |

The 101-test difference is exactly the TLS suite; every other gate is
unaffected, which is what "rollback path" has to mean in practice. The flag
also gates nothing else today — when a guest consumer links the client, that
consumer's build step must be gated on the same option.

### Rollback procedure

1. `zig build test -Dtls_client=false` — confirm the rest of the tree is green
   without the client.
2. If the defect is in the client, ship or deploy with `-Dtls_client=false`
   (and, once a consumer exists, with the consumer's build step gated on the
   same option).
3. The TLS sources stay in the tree; re-enable by dropping the flag.
4. If the flag itself is the problem, `git revert` the single `build.zig` hunk
   that introduces `tls_client_enabled`.

There is no migration step and no persisted state: nothing in the guest links
the library yet, so engaging the pin cannot corrupt anything.
