# ADR 0023: The crypto primitives library — freestanding, host-tested, allocation-free

Status: **ACCEPTED** · Date: 2026-09-11 · Milestone: **M47** (crypto
primitives; goal #1066 Stage 2) · Issues **#1113** (umbrella), **#1114**
(CP0 design)

> Commits the shape of the crypto library before any primitive is written.
> Fixes where the code lives, how the kernel's existing ChaCha20 relates to
> it, what "constant-time" means here, and the allocation/bounds contract
> every API obeys. SSH/TLS are **not** in this milestone — only primitives
> with known-answer vectors. Builds on ADR 0007 (syscall ABI), ADR 0010
> (userland filesystem), and the M34 host file channel.

## Context

Goal #1066 ("get in and out") names Stage 2 as a crypto-primitives
prerequisite: SHA-256 + HMAC, ChaCha20-Poly1305, X25519, Ed25519, and a
constant-time discipline. The tree has exactly one primitive today:
`kernel/src/csprng.zig`, a kernel-internal RFC 7539 ChaCha20 keystream used
for ASLR and transaction ids. There is no hash, no MAC, no AEAD, no
curve arithmetic, and no userland crypto at all.

Two facts shape every decision:

1. **The contract is freestanding.** No libc, no POSIX, no allocator, no
   network. `std.crypto` is deliberately unused (it drags in assumptions the
   project rejects and hides allocation). Everything is caller-buffered.
2. **The vectors are the proof.** Every primitive ships with the published
   RFC/NIST known-answer vectors as class-A `zig test` cases. If a vector
   cannot be met, that is a finding, not a footrace.

The open question this ADR answers is *where the code lives and how the
kernel's cipher relates to it* so the two cannot drift.

## Decision

### D1. One freestanding library, under `user/src/lib/crypto/`
The library lives at `user/src/lib/crypto.zig` (umbrella) plus implementation
files under `user/src/lib/crypto/`:

```
crypto.zig        umbrella re-exports + cross-primitive KATs
crypto/ct.zig     constant-time helpers (ct_eq, ct_select, ct_swap, wipe)
crypto/sha256.zig SHA-256 streaming + HMAC-SHA256
crypto/sha512.zig SHA-512 streaming
crypto/hmac.zig   generic HMAC over a hash descriptor
crypto/chacha20.zig RFC 7539/8439 ChaCha20 block + XOR stream  (shared)
crypto/poly1305.zig RFC 8439 Poly1305 (streaming)
crypto/aead.zig   RFC 8439 ChaCha20-Poly1305 AEAD (seal/open)
crypto/curve25519.zig field/pow/scalar helpers (shared by X25519/Ed25519)
crypto/x25519.zig RFC 7748 X25519
crypto/ed25519.zig RFC 8032 Ed25519 sign/verify
```

It is pure Zig (only `std.mem`/integer ops), class-A testable with a plain
`zig test`, and compiles for both the host and the freestanding AArch64
target. Userland apps consume it by relative import today
(`@import("lib/crypto.zig")`) and can link it as a `.SO` later; no syscall,
no kernel dependency, no I/O.

### D2. The kernel imports the shared ChaCha20 core — no mirror
`kernel/src/csprng.zig`'s `chacha20_block`/`quarter_round` are **re-homed**
into `crypto/chacha20.zig`; `csprng.zig` imports it
(`@import("../../user/src/lib/crypto/chacha20.zig")`) and keeps only what is
kernel policy: the entropy-device seeding, the spinlock, the stream state,
the ASLR placement, and the honest `seeded()` flag. There is **one**
ChaCha20 implementation in the tree, proven by the same RFC vectors in both
test roots. A duplicate "kernel mirror" is rejected: it is the exact drift
risk this ADR exists to prevent. The shared file is already freestanding, so
crossing the `kernel/`-`user/` directory boundary costs nothing at compile
time.

### D3. Constant-time discipline (bounded, honest)
Secret-dependent **branches, memory indices, and early exits are forbidden**;
the helpers in `crypto/ct.zig` carry the discipline:

- `ct_eq`, `ct_ne` — compare without early exit;
- `ct_select(mask, a, b)` / `ct_select_u64` — arithmetic selection;
- `ct_swap` — conditional swap for the Montgomery ladder;
- `wipe` — best-effort zeroization of key material.

Field reduction and the ladder use fixed iteration counts and mask-based
selects; no `while`/`if` on secret bits. **Stated limit:** this is
cache/branch discipline, not a hardened side-channel defense. Zig is not a
constant-time compiler, power/EM analysis is out of scope, and an optimizer
could in principle reshape code — the discipline is enforced by construction,
inspection, and structural tests, and is recorded as such. Ed25519 verify is
public-input and may branch on validity; signing and all X25519 operations
are secret-input and obey D3.

### D4. No allocation; caller-owned, bounded buffers
Nothing in the library allocates, opens files, or performs I/O. Every
operation is one of:

- a **pure value function** over fixed-size arrays (`sha256.digest(out, msg)`),
- a **caller-owned streaming context** passed by pointer
  (`var h: Sha256 = .{}; h.update(buf); h.final(&out);`), or
- a **slice operation** with an explicit output length the caller guarantees
  (`aead.seal(ct, tag, pt, aad, nonce, key)` requires `ct.len == pt.len`).

There is no hidden buffer, no global mutable state, and no unbounded input.
Lengths are `usize` and the APIs document their maximum consumed per call.

### D5. Primitive set and order (CP1–CP5)
| Card | Primitive | Vectors |
|---|---|---|
| CP1 (#1115) | SHA-256, SHA-512, HMAC-SHA256/HMAC-SHA512 streaming | FIPS 180-4, RFC 4231 |
| CP2 (#1116) | ChaCha20 + Poly1305 + ChaCha20-Poly1305 AEAD | RFC 7539 §2, RFC 8439 §2.8 |
| CP3 (#1117) | X25519 scalar multiplication | RFC 7748 §5.2 + §5.2 iterative |
| CP4 (#1118) | Ed25519 sign/verify | RFC 8032 §7.1 |
| CP5 (#1119) | `ct` helpers + `CRYPTOD.BIN` + `live-crypto` gate | host KAT vs guest bytes |

SHA-512 is in scope because Ed25519 requires it. SHA-256 is in scope because
HMAC-SHA256 and the in-guest demo require it. AES-GCM, SHA-1, MD5, Argon2,
scrypt, and any protocol encoding are **out of scope**.

### D6. Verification is two-class
- **Class A:** every vector a `test` block in the library (host `zig test`),
  aggregated by the `crypto.zig` umbrella root listed in `unit_test_sources`.
- **Class B:** `tools/gate/specs/live-crypto.spec` runs an EL0
  `CRYPTOD.BIN` over a share file and asserts the guest's printed digest/HMAC
  bytes equal the host-computed KAT — the guest and the host agree
  byte-for-byte on the same primitive.
- **CP5 randomness:** fixed vectors first; the `csprng` path is exercised
  only after the fixed-vector path is green.

### D7. `crypto.zig` exposes no randomness
The library is deterministic and takes all keys/nonces from the caller.
Randomness stays the kernel's job (`csprng`); a future userland RNG would
obtain bytes via a syscall and feed this library. Keeping RNG out of the
primitive layer means the KAT surface stays pure.

## Consequences

- SSH/TLS become assembly work on proven primitives instead of a crypto
  project; the client-vs-server decision (goal #1066 Stage 3) is deferred
  and unaffected.
- The kernel's cipher and the userland AEAD cannot drift — same file, same
  tests.
- The u256/u512 field arithmetic in `curve25519.zig` favors clarity and
  provable reduction over micro-optimization; it is host/KAT-exercised, and
  the in-guest demo is hash/MAC only, so curve performance is not on the
  critical path. A limb-optimized rewrite can replace the internals without
  changing the API.
- Risk: "constant-time" can be misread as side-channel-proof. D3 states the
  limit plainly so no downstream doc overclaims it.

## Open issues (left to the M47 cards)

- Whether the userland shell/TLS work needs SHA-384 (same core as SHA-512)
  or X25519 precomputation; add only with a vector.
- Whether `LIBUI.SO`-style dynamic delivery of `crypto` is wanted now or
  when the first TLS consumer lands.
- Ed25519 batch verification and context/`Ed25519ctx` variants — not in
  scope; revisit with a driving use case.
