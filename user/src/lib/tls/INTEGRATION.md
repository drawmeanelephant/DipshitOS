# TLS 1.3 client — API and integration guide

Status: shipped 2026-09-14. ADR 0029. Cards #1262/#1264/#1265/#1266/#1267.

This is the public surface of `user/src/lib/tls/`. It is written for whoever
wires the next consumer (an HTTPS fetch path, a git-over-https client, or a
guest `TLS.BIN`), and it is deliberately explicit about what the client will
refuse to do.

## Using it

```zig
const tls_client = @import("client.zig");
const trust_store = @import("trust_store.zig");

// 1. A trust store. The guest should vendor a small set; host tooling may load
//    a full system bundle. Anchors are caller-owned DER.
var store = trust_store.TrustStore.init();      // 64 anchors (guest default)
store.setVersion("virelai-roots-2026-09");
try store.addRoot(root_der);

// 2. A transport. The client never touches sockets itself: it calls read/write
//    on a vtable, so the guest's TCP seam and a host socket are the same code
//    path from the client's point of view.
var client = tls_client.Client(trust_store.TrustStore).init(
    .{ .ctx = ctx, .readFn = readFn, .writeFn = writeFn },
    .{
        .host = "example.com",      // used for SNI and for hostname verification
        .store = &store,
        .now = now_unix_seconds,    // injected so validity is testable
        .entropy = entropy_fn,      // the guest's CSPRNG
        .verify_certificate = true, // leave this on
    },
);

try client.handshake();            // 1-RTT: ClientHello through Finished
try client.write(request);         // only valid from State.connected
const n = try client.read(&buf);   // absorbs tickets/KeyUpdate transparently
```

### The contract the client depends on

- **`readFn`** may return fewer bytes than requested; it must return 0 only on
  a closed connection. The client loops internally for records.
- **`writeFn`** must write everything or return an error; the client loops.
- **`entropy`** must be a real CSPRNG. The client generates its x25519 key and
  its ClientHello random from it.
- **`now`** is injected so that "expired" and "not-yet-valid" are testable states
  rather than faketime fixtures.
- The trust store's DER must outlive the store's use.

### Failure semantics

`handshake()` returns an error and the client is not usable. Errors that matter
to a caller:

| Error | Meaning |
|---|---|
| `ChainValidationFailed` | `client.last_validation` names the exact reason (`hostname_mismatch`, `expired`, `not_yet_valid`, `no_path_to_root`, `name_constraint_violation`, `unknown_critical_extension`, …) |
| `CertificateVerifyFailed` | the leaf's signature over the transcript did not verify |
| `FinishedMismatch` | the server's `Finished` MAC did not verify — the transcript or keys are wrong; treat as hostile |
| `RecordDecryptFailed` | AEAD failure on a record |
| `AlertReceived` | the server sent an alert |
| `UnexpectedMessage` / `UnexpectedState` | an ordering the state machine does not allow |
| `HelloRetryRequestUnsupported` | out of scope by D6 |

**Do not fall back to a weaker protocol on any of these.** The client offers
only TLS 1.3 (`supported_versions` carries a single value), so a server that
wants TLS 1.2 simply fails.

## What is verified, and how

| Layer | File | Pinned to |
|---|---|---|
| Key schedule | `keyschedule.zig` | RFC 8448 §3 (every secret, key, IV, and the Finished MAC) |
| Record layer | `record.zig` | RFC 8448 §3 (the RFC's own encrypted application_data record decrypts) |
| DER / X.509 | `der.zig`, `pem.zig`, `x509.zig` | OpenSSL-generated fixtures, read back via `openssl x509 -text` |
| Identity | `identity.zig` | a 20-case hostname table plus the fixtures |
| Signatures | `rsa.zig`, `ecdsa.zig`, `bigint.zig` | OpenSSL signatures; modexp cross-checked against Python `pow` |
| Chains | `validate.zig`, `trust_store.zig` | OpenSSL chains; 13 positive and negative cases |

## Interop

`interop_driver.zig` is a host program that performs a real handshake against a
real server and prints one JSON ledger line. `interop/ledger.jsonl` is the
recorded matrix: 4 independent local peers (openssl s_server ECDSA, openssl
s_server RSA with an intermediate, gnutls-serv, Go crypto/tls), 8 public
endpoints, and 5 negatives that must fail. `vectors/run_interop.sh` and
`vectors/run_real_endpoints.sh` regenerate it; the local-peer rows are
reproducible in CI containers, the public rows are a recorded networked run.

## Scope limits and known risks

Read these before wiring a consumer:

1. **One cipher suite.** `TLS_AES_128_GCM_SHA256` + x25519 only. A server that
   will not negotiate it cannot be reached. Adding AES-256-GCM or
   ChaCha20-Poly1305 means adding another suite to `handshake.zig`'s offer and
   a second key-schedule instance — the primitives are already present.
2. **No AIA fetching.** If a server omits its intermediate chain, path building
   fails with `no_path_to_root`. Browsers fetch intermediates over AIA; this
   client does not, so an otherwise-valid site can fail. This is a real
   operational limitation, not a bug.
3. **No revocation.** OCSP and CRL are out of scope; a revoked certificate is
   accepted if the chain otherwise validates. This is the single largest
   security gap and needs its own card.
4. **AES is table-based**, so S-box lookups are not cache-timing
   constant-time — the same class of limit ADR 0023 D3 declares.
5. **Verification ladders are not constant-time** (public data; harmless here,
   worth knowing before reusing `bigint.zig` for signing).
6. **RSASSA-PSS certificate signatures are verified as SHA-256** because the
   parser does not read the PSS parameters. PKCS#1 v1.5 is fully covered.
7. **The guest consumer exists but is not runtime-proven.** `FETCHS.BIN`
   (`user/src/fetchs.zig`) is the first guest HTTPS consumer: it connects to
   the host gateway on 443, completes a 1-RTT handshake against the vendored
   root blob, and streams one HTTP/1.0 GET. It compiles, converts and installs
   into the boot image, and its root-loading path is asserted on the host.
   What is *not* proven is the guest actually completing a live handshake,
   because that needs a boot this session could not perform. `fetch.zig` and
   `download.zig` remain plain-HTTP on port 80 and are untouched.

## The gate to land with the consumer

Every `vgate` spec requires a guest boot, so a spec cannot be committed before
the runner side can serve TLS: an unrunnable spec fails the gate fleet.

Two halves of that prerequisite are now met and in-tree:

- **The runner-side responder exists.** `tlsresponder.py` is a TLS 1.3-only
  Python `ssl` responder that serves the fixture identity `FETCHS.BIN` expects
  and exits on a bounded deadline, so it cannot hang a runner. It is exercised
  today by `run_consumer_interop.sh`.
- **The consumer's identity expectation is pinned**: `leaf.example.com`,
  matching the fixture leaf's SAN and its chain to the vendored root.

The remaining half is a *validated* boot. The spec should be:

- `vgate_name live-tls13-handshake`
- `vgate_share seed`, `vgate_runner_flags -Xswiftc -DSPIKE`
- `vgate_setup_python` to start `tlsresponder.py` on a high port bound to the
  gateway address the guest dials
- a `vgate_file` script that runs `FETCHS.BIN` against it
- asserts on the guest serial markers (`fetchs: handshake ok`, the negotiated
  suite, and the response body), plus a negative run that must fail closed
  against a wrong-hostname responder

Class B (Apple silicon VZ). It lands with the first boot that can validate it;
committing it unvalidated would redden the fleet rather than prove anything.
