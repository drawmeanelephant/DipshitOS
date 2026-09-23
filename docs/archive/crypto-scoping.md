# Crypto primitives library (M47) — scoping and gated card split

Status: **OPEN — design accepted (ADR 0023); CP1–CP5 in progress** ·
Date: 2026-09-11 · Milestone **M47** ·
Umbrella **#1113** (goal #1066 Stage 2) · Design card **#1114** ·
Depends on: the M34 host file channel (app delivery), ADR 0007 (syscall
ABI), ADR 0020 (terminal seam, for the demo's console), and
`kernel/src/csprng.zig` (the one existing primitive).

> This document is the milestone's build order. It says what each card
> delivers, the exact APIs, where the known-answer vectors come from, and
> what is deliberately **not** here. The binding design decisions are in
> **ADR 0023**; this document does not restate them, it applies them.

## The one-line pitch

One freestanding, allocation-free, host-tested crypto library
(`user/src/lib/crypto/`) gives the guest the four primitives SSH/TLS are
built from — SHA-256/512 + HMAC, ChaCha20-Poly1305, X25519, Ed25519 — each
proven by the published vectors as class-A tests. The kernel's existing
ChaCha20 stays kernel-local (ADR 0023 D2) and is drift-guarded against the
new cipher by identical RFC 7539 vectors. SSH/TLS are out of scope; this is
the prerequisite.

## Why now, and why this shape

- **Goal #1066 Stage 2 names it.** The staged options (Stage 0 host remote,
  Stage 1 guest remote console, Stage 2 primitives, Stage 3 SSH) put crypto
  before any protocol work. M46 is building the remote-console seam in
  parallel; M47 is independent and safe to run concurrently.
- **The only primitive today is kernel-internal.** `csprng.zig` is a
  ChaCha20 keystream for ASLR/transaction ids. Reusing it (D2) means the
  first cipher is already written and vector-pinned; the work is finishing
  the RFC 8439 surface around it.
- **The test culture fits.** The repo already pins exact bytes in `zig test`
  and in class-B gates. Crypto is the rare domain where the spec ships the
  test vectors, so the KAT discipline is free.
- **Freestanding is a constraint, not a tax.** These primitives are pure
  integer/byte math; a small, auditable implementation is preferable to a
  large library with hidden allocation and platform assumptions.

## Layout (ADR 0023 D1)

```
user/src/lib/crypto.zig            umbrella + cross-primitive tests
user/src/lib/crypto/ct.zig         ct_eq/ct_select/ct_swap/wipe
user/src/lib/crypto/sha256.zig     Sha256 streaming, hmacSha256
user/src/lib/crypto/sha512.zig     Sha512 streaming
user/src/lib/crypto/hmac.zig       generic Hmac(Hash) over a descriptor
user/src/lib/crypto/chacha20.zig   block + xor stream  (userland AEAD core)
user/src/lib/crypto/poly1305.zig   streaming Poly1305
user/src/lib/crypto/aead.zig       ChaCha20-Poly1305 seal/open
user/src/lib/crypto/curve25519.zig field arithmetic + scalar helpers
user/src/lib/crypto/x25519.zig     X25519 scalarmult
user/src/lib/crypto/ed25519.zig    Ed25519 sign/verify
user/src/cryptod.zig               EL0 demo app (CRYPTOD.BIN, DSK1 flat)
tools/gate/specs/live-crypto.spec  class-B guest==host KAT gate
```

`user/src/lib/crypto.zig` is the single `unit_test_sources` entry; Zig runs
the imported files' `test` blocks transitively (verified), so one root covers
the whole suite.

## Card split

| Card | Deliverable | Gate |
|---|---|---|
| **CP0** (#1114) | ADR 0023 + this document, docs-only PR. **Landed first.** | docs review; no code in the PR |
| **CP1** (#1115) | `ct.zig`, `sha256.zig`, `sha512.zig`, `hmac.zig`; streaming contexts | FIPS 180-4 ("abc", 2-block, 1M-'a' where practical) + RFC 4231 cases 1–7; `zig build test` |
| **CP2** (#1116) | `chacha20.zig`, `poly1305.zig`, `aead.zig`; `csprng.zig` stays kernel-local, drift-guarded by the same RFC 7539 vectors | RFC 7539 §2.3.2/§2.4.2 block+ciphertext; RFC 8439 §2.5.2 Poly1305, §2.8.2 AEAD; `csprng` tests stay green |
| **CP3** (#1117) | `curve25519.zig`, `x25519.zig` | RFC 7748 §5.2 single + §5.2 iterative (1, 1000 iterations), §6.1 Diffie-Hellman |
| **CP4** (#1118) | `ed25519.zig` | RFC 8032 §7.1 TEST 1–3 + SHA(abc) vector; sign byte-equality **and** verify accept/reject |
| **CP5** (#1119) | `CRYPTOD.BIN`, `live-crypto.spec`, `build.zig` wiring, gate-inventory regen | class-B `just gate live-crypto` PASS: guest digest/HMAC == host KAT |

Each card lands as its own commit but the milestone ships as one
implementation PR (umbrella #1113) so the library's API is reviewed whole;
CP0 is the only separate PR.

## API sketch (normative once CP1–CP5 land)

```zig
// sha256.zig
pub const Sha256 = struct {
    pub fn init() Sha256;
    pub fn update(self: *Sha256, bytes: []const u8) void;
    pub fn final(self: *Sha256, out: *[32]u8) void;
};
pub fn sha256(out: *[32]u8, bytes: []const u8) void;
pub fn hmacSha256(out: *[32]u8, key: []const u8, msg: []const u8) void;

// chacha20.zig (the userland AEAD core; the kernel keeps its own RFC 7539
// cipher in kernel/src/csprng.zig, drift-guarded by the same vectors)
pub const key_len = 32; pub const nonce_len = 12; pub const block_len = 64;
pub fn quarterRound(state: *[16]u32, a: usize, b: usize, c: usize, d: usize) void;
pub fn block(key: *const [32]u8, counter: u32, nonce: *const [12]u8, out: *[64]u8) void;
pub fn xorStream(out: []u8, in: []const u8, key: *const [32]u8, counter: u32, nonce: *const [12]u8) void;

// poly1305.zig
pub const Poly1305 = struct {
    pub fn init(key: *const [32]u8) Poly1305;
    pub fn update(self: *Poly1305, bytes: []const u8) void;
    pub fn final(self: *Poly1305, out: *[16]u8) void;
};

// aead.zig
pub const tag_len = 16;
pub fn seal(ct: []u8, tag: *[16]u8, pt: []const u8, aad: []const u8,
            nonce: *const [12]u8, key: *const [32]u8) void;   // ct.len == pt.len
pub fn open(pt: []u8, ct: []const u8, tag: *const [16]u8, aad: []const u8,
            nonce: *const [12]u8, key: *const [32]u8) bool;   // pt.len == ct.len

// x25519.zig
pub fn scalarmult(out: *[32]u8, scalar: *const [32]u8, point: *const [32]u8) void;
pub const basepoint: [32]u8 = .{9} ++ .{0} ** 31;

// ed25519.zig
pub const secret_key_len = 32; pub const public_key_len = 32; pub const signature_len = 64;
pub fn derivePublicKey(pk: *[32]u8, sk: *const [32]u8) void;
pub fn sign(sig: *[64]u8, msg: []const u8, sk: *const [32]u8) void;
pub fn verify(sig: *const [64]u8, msg: []const u8, pk: *const [32]u8) bool;
```

All functions are total over their stated lengths, never allocate, never
touch I/O, and never read uninitialized memory.

## Known-answer vector sources

| Primitive | Source | Pinned cases |
|---|---|---|
| SHA-256 | FIPS 180-4 examples; NIST CAVP | `""`, `"abc"`, 56-byte multi-block, 1,000,000×'a' (streaming) |
| SHA-512 | FIPS 180-4 examples | `""`, `"abc"`, 112-byte multi-block |
| HMAC-SHA256 | RFC 4231 | cases 1–7 (keys 20/131 bytes, data variants) |
| ChaCha20 | RFC 7539 §2.3.2, §2.4.2 | block function (serialized state words), 114-byte ciphertext |
| Poly1305 | RFC 8439 §2.5.2 | "Cryptographic Forum Research Group" |
| AEAD | RFC 8439 §2.8.2 | plaintext + AAD, tag, and the empty-AAD variant |
| X25519 | RFC 7748 §5.2, §6.1 | two scalarmult pairs + iterative (1 and 1,000) |
| Ed25519 | RFC 8032 §7.1 | TEST 1, 2, 3, SHA(abc), plus a negative verify |

A vector that cannot be met exactly is reported as a finding in the card's
issue; it is never silently adjusted.

## CP5 — the EL0 demo and the live gate

**`CRYPTOD.BIN`** (`user/src/cryptod.zig`, EL0 app — **DSK1 flat**: it has
no writable globals, so the flat image is the correct fit; the segmented
linker would demand a page-aligned data segment the demo does not need):

```
exec CRYPTOD.BIN <file>
```

1. `sys_file_open(<file>, MODE_READ)` (slot 23) — bare names route to the
   M34 host share.
2. Stream the file in fixed 256-byte chunks into **both** a SHA-256 context
   and an HMAC-SHA256 context (`user/src/lib/crypto.zig`), keyed with the
   fixed demo literal `VIRELAIOS-M47-CRYPTO-DEMO-KEY` — "fixed vectors
   first". No whole-file buffer; memory is O(1).
3. Format one line — `cryptod: sha256=<64 hex> hmac=<64 hex>` — into a
   stack buffer and emit it with **exactly one** `sys_write` (slot 1), then
   `sys_exit(0)`.
4. Any open/read failure prints a distinct refusal and exits non-zero.

**`tools/gate/specs/live-crypto.spec`** (declarative; ADR 0023 D6):

- `vgate_share seed` arms the host share; a setup hook copies `CRYPTOD.BIN`
  from `zig-out/bin` and writes a pinned share file (`CRYPTO.TXT` = the 256
  bytes `0x00..0xff`, each once).
- A script runs `exec CRYPTOD.BIN CRYPTO.TXT` and an `echo` sentinel.
- Assertions:
  - `serial-contains-file expected.txt` — the host-recomputed line must
    occur verbatim in the guest serial (guest bytes == host KAT);
  - `serial-contains` the `exec: loaded CRYPTOD.BIN` line and the sentinel;
  - `serial-absent` every refusal line and `[EXC] parking:`.
- A `python` hook recomputes both values **independently on the host**
  (hashlib/hmac) from the pinned fixture and fails the gate if the spec's
  literal expectations (pinned here as hex) or the generated
  `expected.txt` disagree — so the gate cannot bless a hard-coded wrong
  string.

The gate proves the strongest available claim: the guest's bytes equal the
host's bytes on the same input. It does **not** prove SSH/TLS.

## Non-goals (explicit)

- **No SSH, no TLS, no protocol encoding** (Stage 3).
- **No AES-GCM** (not needed by the chosen modern SSH client suite; add only
  with a driver and vectors).
- **No SHA-1/MD5** (legacy; not in the modern suite).
- **No password hashing** (Argon2/scrypt/PBKDF2) in M47.
- **No randomness in the library** (ADR 0023 D7); `csprng` stays the RNG.
- **No constant-time hardware guarantees** (ADR 0023 D3).

## Risks / open questions

- **Field arithmetic performance.** The u256/u512 Mod-p approach (ADR 0023)
  is chosen for provable reduction, not speed; the in-guest demo does not
  run curve ops. A limb rewrite is safe behind the same API.
- **Cross-directory sharing (decided against).** Zig rejects a relative
  import that escapes the importing file's module path, and several class-A
  gates run `zig test kernel/src/<module>.zig` directly (no build-provided
  modules), so a shared translation unit is not viable without rewriting
  unrelated gate scripts. The kernel keeps its vector-pinned cipher and the
  userland library carries its own; identical RFC 7539 vectors in both test
  roots are the drift guard (ADR 0023 D2).
- **`iterative` X25519 test cost.** 1,000 iterations of scalarmult is fine
  on the host; the test may be gated to a smaller count in CI if needed,
  but the RFC value is asserted exactly when it runs.
- **Dynamic delivery.** Apps import the library statically today; `.SO`
  delivery is a later, additive option.
