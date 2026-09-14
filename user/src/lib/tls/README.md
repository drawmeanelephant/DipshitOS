# TLS 1.3 (RFC 8446) — in-tree client

Status: **first slice landed** — the cryptographic foundation the shelf was
missing, plus the key schedule and record layer, all pinned to published
vectors. The handshake driver, X.509/chain validation and the consumers
(HTTPS, git-over-https) are **not** in this slice; see "What is not here".

Owner: AutoCoder (`agent/autocoder/tls13-c1`). Host-tested, class A, no VM.

## What is here

| File | What it is |
|---|---|
| `../crypto/sha384.zig` | SHA-384 (FIPS 180-4 §6.5); reuses `sha512.compress` |
| `../crypto/hkdf.zig` | HKDF extract/expand (RFC 5869), `Hkdf` over SHA-256/384/512 |
| `../crypto/aes.zig` | AES-128/256 forward cipher + key expansion (FIPS 197) |
| `../crypto/gcm.zig` | AES-GCM seal/open, 96-bit nonce (NIST SP 800-38D) |
| `keyschedule.zig` | RFC 8446 §7.1: `HKDF-Expand-Label`, `Derive-Secret`, traffic key/IV, Finished key, key update |
| `record.zig` | RFC 8446 §5: nonce = IV ⊕ seq, `TLSInnerPlaintext`, AEAD record seal/open |

Two generated vector modules ship beside the code:
`../crypto/aes_gcm_vectors.zig` and `rfc8448_vectors.zig`.

## Why these primitives

The shelf already had SHA-256/512, HMAC, ChaCha20-Poly1305, X25519 and
Ed25519. TLS 1.3 needs three more things before a single byte can be sent:

- **HKDF**, which *is* the TLS 1.3 key schedule (RFC 8446 §7.1);
- **SHA-384**, for `TLS_AES_256_GCM_SHA384` and `ecdsa_secp384r1_sha384`;
- **AES-GCM**, because `TLS_AES_128_GCM_SHA256` is mandatory to implement
  (RFC 8446 §9.1) — a ChaCha-only client cannot talk to a large part of the
  public internet.

Still missing for real-world interop: RSA-PSS / PKCS#1 v1.5 verification and
ECDSA P-256/P-384 verification (needed for certificate chains and for
`CertificateVerify`). Ed25519 certificates let the handshake be proven
end-to-end without them.

## Vector provenance and how to regenerate

Every value pinned in the vector modules was produced by a real
implementation and validated against a published one; nothing was
transcribed from memory. The generators live in `vectors/` in the TLS work
tree and are reproduced here for reproducibility.

| Vector set | Source | Validation |
|---|---|---|
| SHA-384 | Python 3.14.7 `hashlib.sha384` (OpenSSL 3.6.4) | FIPS 180-4 §B.5 examples; the same generator reproduces the SHA-512 vectors already pinned in `sha512.zig` |
| HKDF SHA-256 | RFC 5869 Appendix A cases 1–3 | fetched from `https://www.rfc-editor.org/rfc/rfc5869.txt`; extracted values match the RFC text byte-for-byte |
| HKDF SHA-384/512 | Python 3.14.7 `hmac`/`hashlib` | the generator reproduces the RFC's SHA-256 answers exactly |
| AES blocks | Go 1.27.1 `crypto/aes` **and** OpenSSL 3.6.4 `enc -aes-128-ecb` | generator aborts unless its output matches FIPS 197 C.1/C.3 |
| AES-GCM | Go 1.27.1 `cipher.NewGCM` | generator aborts unless it matches NIST GCM test cases 1 and 2 |
| TLS key schedule / record | RFC 8448 §3 "Simple 1-RTT Handshake" | every block's collected byte count is checked against the octet count printed in the RFC; the handshake messages are checked to parse; the published secrets, keys, IVs and Finished MAC all reproduce |

RFC sources and their sha256 (recorded so a re-fetch can be compared):

| Document | sha256 of the fetched `.txt` |
|---|---|
| RFC 5869 | `7a40eb3835b35fc947eb12a2ed614db079d43b26e50dbc537c31fba16397089c` |
| RFC 8448 | `6564d1376d1ec744fc7a9993da15ebc1b9be361908b166091f47ef605c537fba` |

Regeneration is mechanical: fetch the RFC, run the extractor, run the
emitter. The extractors refuse to emit anything when an octet count does not
match or a handshake message does not parse.

## Verification

```
zig build test
```

covers it (both roots are listed in `build.zig`'s `unit_test_sources`).
Locally the slice was also run standalone:

| Command | Result |
|---|---|
| `zig test user/src/lib/crypto.zig` | 79 tests pass |
| `zig test --dep crypto -Mroot=user/src/lib/tls/keyschedule.zig -Mcrypto=user/src/lib/crypto.zig` | 7 tests pass |
| `zig test --dep crypto -Mroot=user/src/lib/tls/record.zig -Mcrypto=user/src/lib/crypto.zig` | 5 tests pass |

The strongest single result is that the record layer decrypts RFC 8448's own
encrypted `application_data` record — published ciphertext in, published
plaintext out — and that the server's published `Finished` verify_data
reproduces as `HMAC(finished_key, Transcript-Hash(...))`.

## Card C3 — X.509 and identity matching

| File | What it is |
|---|---|
| `der.zig` | Strict DER reader: definite lengths only, minimal length encoding enforced, no trailing bytes, bounded nesting, INTEGER/BIT STRING/BOOLEAN canonical form, UTCTime/GeneralizedTime to Unix seconds |
| `pem.zig` | PEM (RFC 7468) decoding: label match enforced, base64 decoded by hand, only CR/LF/TAB/space skipped |
| `x509.zig` | Certificate parser: version, serial, signature algorithm, issuer/subject CN, validity, SPKI (RSA / EC P-256,P-384 / Ed25519), SAN (dNSName + iPAddress), basicConstraints, keyUsage, extendedKeyUsage, nameConstraints, and the unknown-*critical* extension list |
| `identity.zig` | Hostname matching: SAN over CN, wildcards only as the whole left-most label matching exactly one label, IP literals against iPAddress SANs only, CN fallback reported separately, fail closed |

18 tests: DER 8, PEM 3, parser 4, identity 3 (plus the DER suite they import).

Fixtures are generated by `vectors/make_x509_fixtures.sh` (OpenSSL 3.6.4) —
a P-256 root, a P-256 intermediate with `pathlen:0`, an ECDSA leaf with a
dNSName SAN and a wildcard, an RSA-2048 leaf, a leaf with iPAddress SANs, a
name-constrained CA and its leaf, a leaf with an unknown **critical**
extension, and a leaf with no SAN at all. `vectors/emit_x509_vectors.py` then
reads every expected value out of `openssl x509 -text` and refuses to emit if a
count or a name disagrees with what the fixture set should contain.

Honest bound: a wildcard in a public-suffix position (`*.co.uk`) cannot be
refused without a public-suffix list, which this library does not ship. The
rule enforced is the strongest one available locally — wildcard only as the
entire left-most label, matching exactly one label, never a bare TLD — and the
limitation is stated in `identity.zig`'s header rather than papered over.

## What is not here

- X.509 / DER / PEM parsing, hostname matching, chain validation, trust store.
- RSA-PSS / RSA-PKCS#1 v1.5 and ECDSA P-256/P-384 verification.
- The `ClientHello → Finished` state machine and the handshake driver.
- Interop runs against OpenSSL / GnuTLS / Go and live endpoints; the test
  ledger.
- Wiring the HTTPS browser and git-over-https consumers.
- The ADR, the class-B gate spec and the `docs/status.md` row.

Known limitation, stated rather than hidden: the AES implementation is
table-based, so S-box lookups are not cache-timing constant-time. That is the
same class of limit ADR 0023 D3 already declares for this library.
