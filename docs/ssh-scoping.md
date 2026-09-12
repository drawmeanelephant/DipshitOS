# SSH (M51) — scoping and gated card split

Status: **OPEN — design accepted (ADR 0025); SSH-P1/P2 + SSH1–SSH5 filed,
not started** · Date: 2026-09-12 · Milestone **M51** (goal **#1066**
Stage 3) · Umbrella **#1164** · Design card **#1165** (SSH0) · Depends on:
the M46 remote seam (ADR 0022, `--net` + `--net-tcp-respond`), the M47
primitives (ADR 0023, `user/src/lib/crypto/`), the M50 secret store and
delegated auth (ADR 0024 D6/D7/D8), ADR 0007 (syscall ABI), and the
`netauth.zig` injected-seam test pattern.

> This document is the milestone's build order. It says what each card
> delivers, how it is verified, and what is deliberately **not** here. The
> binding design decisions are in **ADR 0025**; this document does not
> restate them, it applies them.

## The one-line pitch

A guest SSH-2 **client** — `SSH.BIN` — dials **out** to a host, proves the
server's `ssh-ed25519` host key against a pinned share file, authenticates
with an Ed25519 `publickey` signature using a seed from the M50 secret
store, and drives an encrypted `chacha20-poly1305@openssh.com` channel that
runs a remote command or an interactive shell. The kernel gains exactly one
syscall (an entropy read) and stays crypto-free; a userland stream adapter
turns the bounded, reassembly-free TCP seam into a real packet stream.

## Why now, and why this shape

- **Goal #1066 names Stage 3 = SSH, and the prerequisites just landed.**
  M46 built the net front-end; M47 shipped SHA-256/512 + HMAC, ChaCha20,
  Poly1305, X25519, and Ed25519; M50 built the secret store and proved that
  crypto verification is delegated to userland. SSH is now assembly work on
  proven primitives instead of a crypto project.
- **"Get out" is more useful and more testable than "get in".** A client
  needs no host→guest forward; the runner's `--net` emulation already has a
  deterministic host TCP peer. A server needs a port-forward story that does
  not exist (ADR 0025 D1).
- **The kernel seam is the hard part, and it is not changed.** The SSH
  binary packet is variable-length; the kernel RX is one 192-byte slot with
  no reassembly. The milestone's centre of gravity is therefore the userland
  packet/stream layer (SSH1), not a kernel rewrite (ADR 0025 D6).
- **Honesty over theatre.** `curve25519-sha256` + `ssh-ed25519` +
  `chacha20-poly1305@openssh.com` + `publickey` is a real, interoperable
  profile; the missing OpenSSH cipher is an explicit prerequisite card, not
  an assumption; and the gate is client-side because that is what the VZ NAT
  can actually prove.

## Protocol profile (ADR 0025 D2)

| Role | Offered (M51 only) | Shipped primitive |
|---|---|---|
| Transport | SSH-2.0 (RFC 4253) | — |
| KEX | `curve25519-sha256` (RFC 8731) + `curve25519-sha256@libssh.org` | `x25519.scalarmult` + `sha256` |
| Host key | `ssh-ed25519` (RFC 8709) | `ed25519.verify` |
| Cipher | `chacha20-poly1305@openssh.com` | new (SSH-P2), on `chacha20`/`poly1305`/`ct` |
| MAC | none (AEAD) | — |
| Compression | `none` | — |
| User auth | `publickey`, `ssh-ed25519` (RFC 4252 §7) | `ed25519.sign` |

**Missing primitive (prerequisite, not assumption):** the OpenSSH cipher is
the original djb ChaCha20 (64-bit nonce = packet sequence number, 64-bit
counter) with a split 64-byte key and Encrypt-then-MAC over
`enc_length ‖ enc_payload`. The RFC 8439 `crypto/aead.zig` and the 12-byte
nonce `crypto/chacha20.zig` **cannot** be used. SSH-P2 adds
`crypto/chacha20_ssh.zig` + `crypto/ssh_cipher.zig`, pinned to the OpenSSH
`PROTOCOL.chacha20poly1305` vector. (The IETF draft names K_1/K_2 inverted
from the OpenSSH file — implement to the OpenSSH file.)

## Hard constraints (stated, scoped around)

1. **The kernel TCP seam is single-connection, bounded, and has no
   reassembly.** `payload_max = 192`, `segment_max = 212`,
   `frame_max = 246` (`kernel/src/tcp.zig:63-67`); an oversized RX payload is
   dropped (`:634`); a segment arriving while the one-slot RX buffer is full
   is dropped **and not ACKed** (`:765`). `sys_tcp_recv` (slot 32) returns at
   most one ≤192-byte chunk. This makes the **userland stream adapter /
   packet layer (SSH1) mandatory**: it reassembles SSH packets across chunks,
   drains the slot promptly, paces TX to one outstanding segment, and fails
   closed on overflow. Correctness under a dropped segment leans on the
   peer's TCP retransmission, and the throughput ceiling is
   segment-at-a-time — both stated, not hidden. No kernel RX ring in M51.
2. **No kernel crypto imports (ADR 0023 D2).** SSH lives in userland on the
   M47 primitives; the kernel only returns entropy bytes and moves TCP bytes.
   There is no kernel `sha256`/`ed25519`/`chacha` call anywhere in this
   milestone.
3. **One syscall slot at most per card.** The only new slot is SSH-P1's
   `sys_getrandom` (slot 72; `implemented_count` 72 → 73). Every other card
   adds zero. The delegated-auth / secret-store patterns are reused rather
   than inventing kernel surface: `sys_secret_get` (slot 70) supplies the
   key, the file ABI supplies the public pins.
4. **Spec-first gates (AGENTS.md M40 GF6).** Class A for the protocol/state
   machines (pure, injected seams like `user/src/lib/netauth.zig`); class B
   is a declarative `tools/gate/specs/live-ssh-*.spec`, discovered by
   `tools/gate/fleet.sh`, never a one-off shell script.
5. **Boot default unchanged is a must-observe.** No SSH code on the boot
   path; `sys_getrandom` registered but not called at boot; nothing listens
   and nothing dials unless a process asks; the existing class-B fleet stays
   green.

## Layout (expected files; a card may adjust within its scope)

```
user/src/lib/ssh/wire.zig          NEW  SSH byte/string/mpint/name-list codec (SSH1)
user/src/lib/ssh/packet.zig        NEW  RFC 4253 binary packet framing (SSH1)
user/src/lib/ssh/stream.zig        NEW  stream adapter over sys_tcp_* (SSH1)
user/src/lib/ssh/kex.zig           NEW  version/KEXINIT/curve25519-sha256/NEWKEYS (SSH2)
user/src/lib/ssh/userauth.zig      NEW  none probe + publickey ed25519 (SSH3)
user/src/lib/ssh/channel.zig       NEW  session/pty/exec channels (SSH4)
user/src/ssh.zig                   NEW  SSH.BIN app + CLI (SSH4)
user/src/lib/rng.zig               NEW  sys_getrandom wrapper (SSH-P1)
user/src/lib/crypto/chacha20_ssh.zig  NEW  djb ChaCha20, 64-bit nonce/counter (SSH-P2)
user/src/lib/crypto/ssh_cipher.zig    NEW  chacha20-poly1305@openssh.com (SSH-P2)
kernel/src/syscall.zig             slot 72 sys_getrandom (SSH-P1)
host/vm-runner/Sources/VMRunner/main.swift  --net-tcp-respond …:ssh (SSH5)
tools/gate/specs/live-ssh-*.spec   NEW  class-B fleet (SSH5)
SSH/KNOWN_HOSTS (share)            host-seeded pins (SSH3/SSH5)
SECRETS.TXT (share)               ssh-user-ed25519 seed, uid 1000 (SSH3/SSH5)
```

The SSH library is a sibling of `netauth.zig` — the M50 delegated-auth
verifier the guest runs when it *hosts* the remote door. The two share the
crypto library and the OS seams, not the protocol or the direction.

## Card split and acceptance

| Card | Deliverable | Class-A acceptance | Class-B acceptance | Boot default |
|---|---|---|---|---|
| **SSH0** #1165 (this doc) | ADR 0025 + this scoping doc, docs-only PR | docs review; no code | none | unchanged |
| **SSH-P1** #1166 | `sys_getrandom(buf, len)` slot 72; `lib/rng.zig`; ADR 0007 table + count 72→73 | bounded length (cap; `len==0`→0; `EFAULT` bad buffer), no capability, table/count pinned; no boot-path call | a probe (or SSH2's fresh-key proof) shows entropy reaches EL0; fleet green | slot registered, never called at boot |
| **SSH-P2** #1167 | `crypto/chacha20_ssh.zig` (djb, 64-bit nonce/counter) + `crypto/ssh_cipher.zig`; OpenSSH construction | OpenSSH `PROTOCOL.chacha20poly1305` vector (Poly key `76b8e0ad…`); seal/open round trip; tag tamper reject via `ct.ctEq`; sequence-number nonce advances | none (crypto KAT is class-A); fleet green | no code on boot path |
| **SSH1** #1168 | `ssh/wire.zig`, `ssh/packet.zig`, `ssh/stream.zig` | wire round-trips (byte/uint32/uint64/string/mpint/name-list); packet length/padding bounds; split-packet reassembly; ring-overflow **fail-closed**; one-outstanding-segment TX pacing — all over an injected seam | a deterministic responder sends a known packet split across many segments; the guest reassembles and echoes a digest | untouched |
| **SSH2** #1169 | `ssh/kex.zig`: version exchange, KEXINIT, `curve25519-sha256`, `ssh-ed25519` host-key verify, exchange hash `H`, KDF, NEWKEYS, cipher install | pinned RFC 8731/4253 KEX vectors; wrong host-key sig / tampered `H` / wrong `session_id` rejected; derived keys match the KDF | covered by SSH5's positive run | untouched |
| **SSH3** #1170 | `ssh/userauth.zig`: service request, `none` probe, `publickey` ed25519 signature; `SSH/KNOWN_HOSTS` parser; TS5 `ssh-user-ed25519` read + `ct.wipe` | signature over `session_id ‖ request` verifies; wrong key refused; `none`→`publickey` flow; missing key/pin fails closed with a distinct status; secret never logged | covered by SSH5's positive/negative runs | no secret read at boot |
| **SSH4** #1171 | `ssh/channel.zig` + `user/src/ssh.zig` (`SSH.BIN`): session open, `pty-req`/`shell` or `exec`, data/window/EOF/close; CLI `SSH.BIN [user@]host[:port] [cmd]` | channel state machine, window accounting, EOF/close, exec-vs-pty dispatch; no-rekey byte/packet bound disconnects | SSH5 drives a one-shot `exec` marker and an interactive shell line | untouched |
| **SSH5** #1172 | runner `--net-tcp-respond …:ssh` minimal SSH server (pinned host key + pinned publickey + one exec); `tools/gate/specs/live-ssh-*.spec`; inventory regenerated | — (gate card) | positive KEX+auth+exec; unknown host key refused; wrong user key refused; tampered MAC disconnected; missing credential fail-closed; `serial-absent '[EXC]'` | fleet re-run green |

Each implementation PR updates ADR 0007's table and `implemented_count` where
it adds a slot (only SSH-P1), regenerates `docs/gate-fleet-inventory.md` when
it adds a spec (SSH5), and presents `boot-default-unchanged` evidence.

## Implementation order

```
SSH0 (design) ──┬──► SSH1 (packet/stream) ──────┐
                ├──► SSH-P1 (entropy, slot 72) ──┼──► SSH2 ──► SSH3 ──► SSH4 ──► SSH5
                └──► SSH-P2 (OpenSSH cipher) ───┘
                (independent, any order)          (KEX)     (auth)    (SSH.BIN) (gate)
```

- **SSH0 first** — this docs PR; it freezes the suite, the stores, and the
  boundary so no later card re-litigates them.
- **SSH1, SSH-P1, SSH-P2 are independent** after SSH0 and may land in any
  order (SSH1 is the largest; the two prerequisites are small and unblock
  SSH2).
- **SSH2 needs all three**, because KEX both flows through the adapter and
  consumes entropy and the cipher.
- **SSH3 then SSH4** — userauth before channels; `SSH.BIN` is the first
  user-visible payoff.
- **SSH5 last** — the endpoint gate exercises the whole stack, so it lands
  once the client is complete; negative runs are written alongside.

If a single session cannot land the whole milestone, the umbrella rule
applies: land the smallest complete slice with its gate (SSH-P1 + SSH1 with
class-A proof) and leave the rest on the tracker — the cards exist as
#1166–#1172.

## Threat model

**Protected:** the SSH session's **confidentiality and integrity** after
NEWKEYS (AEAD over every packet); **server authentication** to a pinned
`ssh-ed25519` host key (a changed key is refused, not warned); **client-key
confidentiality** (the Ed25519 seed lives in the file-ABI-denied secret
class, is read only through `sys_secret_get`, and is wiped after use);
**freshness** (ephemeral X25519 keys + `session_id` make a captured session
non-replayable); the kernel stays out of the crypto trust base.

**Not protected, by decision:** the M50 inbound remote door (plaintext,
unchanged by M51); the **server** direction (does not exist yet); a
compromised host or a malicious pinned key (a pin is trust, not proof);
availability (the segment-at-a-time adapter is slow and there is no
rate-limit/rekey); password/keyboard-interactive auth (not offered); a
side-channel-proof implementation (ADR 0023 D3's stated limit); and
multi-user isolation beyond TS5 `uid` scoping.

## Non-goals (explicit)

- **No SSH server, no listener, no port forward** (ADR 0025 D1).
- **No kernel crypto import and no kernel TCP rewrite** (ADR 0025 D4/D6).
- **No TLS** (ADR 0024 D7 stands); SSH is the session-encryption card.
- **No RSA/ECDSA/DSA, no AES-GCM/CTR, no bignum** — the suite is exactly
  the table above.
- **No password / keyboard-interactive / agent / forwarding / SCP / SFTP /
  X11 / certificates.**
- **No rekey in M51** (bounded reconnect instead).
- **No `sys_secret_set`** — provisioning stays host edits the share file.
- **No new syscall slot beyond slot 72.**

## Risks / open questions

- **The one-slot RX drop is the sharp edge.** Correctness rests on the peer
  retransmitting the un-ACKed dropped segment; the adapter must drain
  promptly and the gate responder must pace. If a real server floods
  back-to-back segments, throughput collapses to the RTO — stated, and the
  driver for the deferred kernel RX ring.
- **The kernel does not validate RX sequence numbers.** The adapter assumes
  the peer's in-order TCP guarantee; a hostile peer could desynchronize the
  stream. Fail-closed parsing bounds the damage, but it is an assumption.
- **Swift responder ↔ Zig client cipher drift.** SSH-P2's pinned OpenSSH
  vectors must be asserted on both sides (ADR 0023 D2 precedent); if the
  Swift implementation is rejected, the custom-virtio bridge is the fallback.
- **Ephemeral key entropy is a new kernel surface.** Slot 72 is small and
  ownerless by design; SSH-P1 must prove it cannot be called on the boot
  path and does not weaken the CSRNG (it only reads it).
- **Real-OpenSSH interop is unproven until run.** The hermetic gate proves
  the profile against our own responder; the documented real-`sshd` run is
  the honesty check, and it may surface conformance gaps (packet padding,
  window sizes, the exact `mpint` encoding of the shared secret).
- **Key provisioning UX.** Two host-edited files (`SECRETS.TXT`,
  `SSH/KNOWN_HOSTS`) with no in-guest setter; the human must hex-encode keys.
  A future card may add a provisioning helper or OpenSSH-format import.
