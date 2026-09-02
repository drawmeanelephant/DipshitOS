# WASM core interpreter (M35 proposal) — scoping sketch and gated card split

Status: **OPEN — W1a + W1b + W2 + W3 + W4 landed (#778, #762–#765); W5 (`wc`, #766) remains** · Date: 2026-09-01 (updated 2026-09-02) ·
Frozen import contract: **`docs/wasm-import-contract.md` (W1a #778) — normative for W3 (#764) + W5 (#766)** ·
Derived from: the custom-virtio file channel (M34 HF1–HF3, claims 7710/9459),
ADR 0007's syscall ABI, the M32 in-guest compiler ladder (zc, #749–#761), and
the M29 VM seam (`sys_mmap` slot 63).

> This document turns a recurring design conversation into a concrete,
> gated, milestone-shaped proposal. The pitch is simple: **one interpreter
> written once turns the guest from a "supports Zig" machine into a "runs
> the ecosystem" machine** — C, Rust, Go, AssemblyScript, and anything else
> with a wasm backend, all host-built, all dropped into the share folder
> like any HF4 app. It is NOT a commitment to start — it is the seed.

## The one-line pitch

A bounded **wasm-core interpreter** written in Zig, running as an EL0 app
(`WASM.BIN`), reading wasm modules as *data* through the M34 file channel,
with a **custom import surface mapped to ADR 0007 syscalls** — not WASI,
which is POSIX-shaped. The host compiles C/Rust/Go to wasm; the guest runs
them. Module = data = no ELF contract, no loader changes, no new syscalls.

## Why this composes with everything (the survey)

- **WASM sidesteps the ELF contract entirely.** A wasm module is data, not
  an ELF: it never touches `exec.zig`, never hits the 256 KiB load cap, the
  `0x00400000` base, or the 2-PT_LOAD rule. The interpreter reads it through
  the file channel (HF2/HF3 — already merged). Only the interpreter binary
  itself rides the normal ELF exec path, and you control that build.
- **The host toolchain already exists — measured on this machine:**
  - `zig cc -target wasm32-freestanding -nostdlib` → **684-byte module**
    for a trivial C program (zig ships its own wasm linker — no `wasm-ld`
    needed).
  - clang 21 present but needs `brew install wasm-ld` for `--target=wasm32`
    (one-time host tooling, not a design problem).
  - rustc 1.96 lists `wasm32-unknown-unknown` + `wasm32-wasip1` (target
    install is one `rustup target add`).
  - go 1.27 builds `GOOS=wasip1 GOARCH=wasm` — **1.9 MB for an empty
    program** (Go's goroutine runtime ships to wasm). Fat but works; and
    because modules are data, size is irrelevant to the loader — the
    interpreter just streams them in chunks.
- **The syscall surface is ready.** ADR 0007 gives every import a target:
  write (1), exit (3), sleep (4), ipc (5/6), procs (7), wait (8), udp
  (9–11), win (12–20), file (23–27 + 34–37), exec (28), kill (29), tcp
  (30–33), timers (40/41), audio (42–45), mmap (63), wmctl (65). The
  interpreter dispatches imports → `svc` — zero kernel changes.
- **Zero new syscall slots, zero kernel changes — the whole milestone is
  userland.** Like the M32 lanes: the interpreter is an EL0 app, imports
  are dispatch inside it. This is the "pays off early" argument.
- **The compiler ladder feeds it.** The interpreter is a natural customer
  for zc (Z0.5+): once the dialect contract lands, parts of it can be
  written in-guest. And the AOT off-ramp (wasm → AArch64 via `asmenc.zig`)
  compounds rather than fights.
- **Determinism fits the fixture culture.** Wasm modules are byte-identical;
  the interpreter is deterministic. Gate fixtures can pin exact output —
  the repo's whole byte-exact discipline applies as-is.

## Design sketch

### 1. Module = data, interpreter = app

```
host:  zig cc -target wasm32-freestanding -nostdlib app.c  →  app.wasm  (684 B)
       (or rustc --target wasm32-unknown-unknown, or GOOS=wasip1 go build)
       →  drop app.wasm into the --cvc-file share folder

guest: exec WASM.BIN app.wasm            (or `wasm run app.wasm`)
       →  interpreter streams the module via the file channel (READ at
          offsets, 32 KiB chunks — HF1/HF2 proven)
       →  validates, instantiates, runs
       →  imports dispatch to svc calls
```

### 2. The interpreter core (bounded)

A **wasm-core integer subset first**, growing honestly:

| Feature | In first slice | Later |
|---------|----------------|-------|
| Value types | i32, i64 | — (f32/f64 landed in W4, claim 7395) |
| Control flow | block/loop/if/br/br_if/br_table/return/call/call_indirect | — |
| Linear memory | one bounded memory, **2 MiB (32 pages) cap — trap on `memory.grow` beyond** (mmap-backed via slot 63) | multiple memories (spec later) |
| Tables | one function table (call_indirect) | — |
| Traps | bounds, call_indirect type, divide-by-zero, unreachable, invalid_conv (plain trunc NaN/overflow), grow_limit, stack overflow | — |
| Threads / atomics / SIMD / GC / multi-memory / 0xFC table ops (≥12) | **never in scope** (bounded by design) | — (bulk-memory 0xFC 8–11 + trunc_sat 0xFC 0–7 landed in W4 — no longer a trap) |

Bounded like zc: one source file, fixed buffers, no heap in the interpreter
itself (or a tiny bump arena if W3's file apps need it). Every trap names
its module + offset, in the "every diagnostic names its line" tradition.

### 3. The import surface (the contract — NOT WASI)

WASI is POSIX-shaped — the thing the project rejects on principle. Instead
the interpreter defines its own import namespace mapped to ADR 0007, e.g.
`env.write(fd, ptr, len) → svc 1`, `env.exit(status) → svc 3`,
`env.win_open(x,y,w,h) → svc 12`, … The mapping table is a frozen contract
(**W1a — `docs/wasm-import-contract.md`**) before any breadth (W3). Host toolchains link against a tiny `virelai.h`
/ `virelai.zig` shim that emits `env.*` imports — so the C source is
ordinary freestanding C with `#include "virelai.h"`.

### 4. The AOT off-ramp (future, optional)

Later, the interpreter can compile hot wasm → AArch64 using `asmenc.zig`
(the encoder the in-guest assembler and zc already use) — an interpreter
today, a JIT later, same pieces. Explicitly NOT in this milestone; the
interpreter's structure (linear memory + typed calls) is what makes the
off-ramp possible without rework.

## Gated card split

| # | Card | Depends | Gate |
|---|------|---------|------|
| W1a | **Import contract freeze** (#778) — the checked-in `docs/wasm-import-contract.md`: frozen `env.*` → ADR 0007 mapping (file 23–27 + 34–37, win 12–20, audio 42–45, timers 40/41, mmap 63, procs 7, wait 8), argument shapes + error mapping; **decisions pinned: Go wasm deferred to post-M35 (option b), 2 MiB / 32-page memory cap, W5 capstone = `wc`** | — (docs-only; parallel with W1b) | the contract doc is checked in and reviewed; W3/W5 point at it; a fresh host author can implement any listed import from it alone |
| W1b | **Core interpreter** (#762) — `user/src/wasm.zig` (path frozen; builds `WASM.BIN`): wasm binary parse + validation + integer-subset execution (i32/i64, control flow, one bounded memory with 32-page cap + grow-trap, `call_indirect`, traps named with module+offset), host unit tests on parse AND exec; `tests/wasm-corpus/` starts here | — (parallel with W1a) | `zig test`: a hand-built module executes deterministically; each trap class fires named; `memory.grow` past 32 pages traps; BSS before/after recorded |
| W2 | **First user surface + live proof** (#763) — `exec WASM.BIN <file>` (HF4 app delivery); module read through the file channel; class-B gate: host builds a C hello-world with `zig cc` (684 B), drops it in the share, guest runs it and the output is observed; `wasm run` monitor command optional/deferred | W1b | `tools/verify-live-wasm.sh` PASS on VZ: `write` import lands on the console byte-exact, `exit` status observed, shell alive |
| W3 | **Import breadth** (#764) — the frozen syscall set (file, win, audio, clipboard, timers, mmap) behind `env.*` imports per the W1a contract; a wasm window app and a wasm file app; `virelai.h`/`virelai.zig` host shims | W2 + W1a | live gate: wasm window app's fill observed via the existing scanout/capture path; wasm file app's read verified byte-exact |
| W4 | **Core completeness** (#765) — f32/f64, sign-extension ops, bulk-memory only as justified by the capstone; floats tied to a **named C float utility** (`zig cc`, pinned output) — not `wc`, which is integer-only | W3 | ✅ **DONE 2026-09-02** (claim 7395): named C float utility `tests/floatapp.c` pinned c963d5aa; live gate asserts five float opcode families byte-exact + exit 590; determinism fixtures extend `tests/wasm-corpus/` |
| W5 | **The ecosystem capstone** (#766) — **`wc`**: byte/line/word counts via file-channel reads, byte-exact; shipped as an HF4 app; the import contract rewritten to standalone-author standard, proven by a fresh host author writing a working `virelai.h` program from the doc alone | W4 | the `wc` app ships and runs in a live gate with byte-exact counts; a second app written from the contract doc alone compiles and runs |

W1b+W2 can be one claim if reviewers prefer a single vertical slice (the
HF1+HF2 pattern — prove the whole concept in one PR); W1a is docs-only and
can be claimed in parallel by a second agent.

**What W4 landed (claim 7395, `docs/march-m35-w4-core-completeness.md`):**
f32/f64 value types + the full float opcode surface (consts, load/store,
cmps, unary/binary, converts, reinterpret) with the W1 trap discipline —
float div-by-zero yields ±inf and never traps, the plain trapping trunc
family (0xA8–0xB1) traps NaN/out-of-range as `invalid_conv`, and the
saturating forms (0xFC 0–7, what clang lowers C casts to) clamp and never
trap. Sign-extension ops (0xC0–0xC4) were already in W1b's integer set;
W4 exercises them with a proof fixture. Bulk-memory 0xFC 8–11
(`memory.init/copy/fill`, `data.drop`) was **justified by a compile probe**
(clang emits `memory.copy`/`memory.fill` for runtime-size memcpy/memset
under the plain W3 recipe) and landed with the DataCount section + passive
data segments. The named C float utility runs byte-exact in-guest: its
590-byte output is asserted line-by-line (five opcode families) with exit
status 590 in `tools/verify-live-wasm.sh`. Interpreter-side W4 surface:
`user/src/wasm.zig` (+~600 lines over W3); WASM.BIN 63,456 B, inside the
256 KiB loader budget.

## Risks and honest limits

- **The interpreter is real software.** A correct wasm-core validator +
  executor is a genuine milestone-sized effort (module structure, type
  checking, the full integer opcode set, trap semantics). The bounded
  subset (no floats first) keeps it tractable and honest; W4 grows it only
  with justification.
- **Imports are the security boundary.** The guest grants wasm code exactly
  the `env.*` imports it exposes — the same untrusted-code posture as the
  file channel (the host runner sandboxes the share; the interpreter
  sandboxes the module). The mapping table must be the frozen, reviewed
  contract (W1), not grown ad hoc.
- **Host toolchain gaps.** clang needs `wasm-ld` installed (one brew);
  rust needs `rustup target add wasm32-unknown-unknown`; Go's wasm output
  is 1.9 MB (fine as data, but a streaming read of 1.9 MB is ~58 round
  trips at 32 KiB — fine, but a documented latency, not an assumption).
- **Performance** — an interpreter is slower than native. Fine for the
  experience layer; the AOT off-ramp is the documented later answer.
- **Go's runtime needs WASI-ish imports — decided, not assumed.**
  `GOOS=wasip1` output imports WASI symbols, not `env.*`. **Resolved
  2026-09-01 (W1a, #778): option (b)** — Go wasm is deferred to post-M35;
  the WASI-shim question is documented, not built, and W2's gate uses only
  the 684-B `zig cc` fixture (no 1.9-MB fixture, no shim, in the first PR).
- **Not a systems language.** Wasm apps can't touch kernel-touching work
  Zig does; it's for app breadth, not depth. The Zig/zc ladder stays the
  crown jewel; this is additive, not a replacement.
- **Existing gates stay green.** The interpreter is additive — default
  boots have no WASM.BIN surface; `wasm run` prints an honest line when
  absent, same as `vf` before `--cvc-file`.

## Explicitly out of scope

- **WASI** — POSIX-shaped by design; rejected on principle (same reason
  FUSE/virtio-fs were). The import surface is the project's own, mapped to
  ADR 0007.
- **Threads, atomics, SIMD, shared memory** — never; the bounded subset is
  the point.
- **A wasm JIT in this milestone** — the AOT off-ramp is documented as the
  future structure, not committed.
- **Replacing zc or the Zig story** — the in-guest compiler ladder
  (#749–#761) is orthogonal and continues.
- **A guest filesystem, guest network stack, or anything that grows the
  kernel** — this milestone is pure userland by construction.
