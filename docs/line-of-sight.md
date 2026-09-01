# Line of sight — what's workable on the current board

Status: **maintained manually against GitHub** · Date: 2026-09-01 ·
Sources: GitHub API (milestones/issues), current `origin/main` (`1346855`),
claims 7710/9459/7599/0098/1263. This doc mirrors the GitHub board so we can pick the
next thing without opening the browser. It is not a milestone tracker —
`docs/status.md` owns milestone-level truth; this is the "what can I claim
next" view. Keep the tables honest: **observed** = merged/live-gated, not
"should land soon".

## M34 — FAT-free storage (milestone #21)

The other agent's thread. HF1–HF4 are **merged on main**; HF5–HF7 are the
remaining steps.

| Card | Issue | State | Evidence / what remains |
|------|-------|-------|-------------------------|
| HF1+HF2 — wire + transport + `vf ls`/`vf cat` | #735/#736 | ✅ **merged** (PR #745, claim 7710) | queue 5, VF_PROBE 32 KiB device-write spike, LIST/READ/STAT, `VFWire` module + fixtures, `verify-live-vf.sh` |
| HF3 — mutation (OPEN/CLOSE/WRITE/TRUNCATE/RENAME/MKDIR/DELETE/FSYNC) | #737 | ✅ **merged** (PR #747, claim 9459) | additive ops 0x04–0x0b, 8-slot host handle table, WRITE ≤ 32,763 B chunks, FSYNC durability |
| HF4 — app delivery from the host folder | #738 | ✅ **merged** (PR #769, claim 7599) | drop a `.ELF` in the share, `exec` it; desktop manifest re-pointed; dual path with ESP until HF6 |
| HF5 — user-data migration to the host folder | #739 | 🔶 **open** | re-point every `/data` consumer (settings, notepad, calc history, downloads, screenshots, shell history, clipboard); `/data` deprecation line |
| HF6 — FAT removal | #740 | 🔶 **open** | delete `fat.zig` + post-exit virtio-blk + DATA partition; slim image; gate fleet to one shared read-only boot image |
| HF7 — CLONE → `clonefile` COW dedup | #741 | 🔶 **open** | the worktree capstone; host-side du before/after under `artifacts/` |

**Workable now:** HF5 (user-data migration) is the largest remaining card —
every persistence consumer re-points to the host folder. HF6 (FAT removal)
is the deletion payoff and must be last. HF7 (CLONE dedup) is parallel
(depends only on HF3) and is the worktree capstone.

## FAT32/FAT pain points — inventory and coverage

Every documented FAT pain point, the card that fixes it, and whether that
card has actually landed. Two rows are **GAPS** — the channel as merged does
not fix them, and they are wire-shape decisions already baked into fixtures.

| # | Pain point (documented where) | Fixed by | Status |
|---|-------------------------------|----------|--------|
| 1 | **2048-byte read cap** — `fat.cat`/`read_file` honest 2048-B cap; `esp_content_max` = 2048 B (claim 6344, m4 logs) | HF1/HF2 READ-with-offset, 32 KiB reply | ✅ merged — reads are stateless streams to arbitrarily large files |
| 2 | **2048-byte write/truncate cap** — `write_content_max` = 2048, `sys_file_truncate` ≤ 2048 (ADR 0007 slot 36; `file_table.zig` staging) | HF3 WRITE/TRUNCATE (32,763-B chunks) **at the channel** | ⚠️ **partial** — the channel is cap-free, but the userland syscall ABI (ADR 0010 slots 23–27, `file_table.zig`) still routes through FAT with the 2048 caps until HF5 re-points it. Notepad/settings/downloads still hit the old caps today |
| 3 | **8.3 short names** — leading-dot names unrepresentable (`.recent` → `RECENT.SAV`), padded names (`"CALC    "`), case-insensitive mapping (march-m25 F5, m13 logs) | HF2 LIST serves real host names | ✅ merged — names are host-truth, case-preserving, leading-dot OK |
| 4 | **Long filenames truncate at 31 bytes** — the merged LIST row is `[name 31][type u8][size u64le]` (40 B), inherited from ADR 0010's 31-char display name | — | ❌ **GAP** — a macOS file with a >30-char name truncates in the guest listing. Wire shape already baked into fixtures; changing it is a wire revision (additive op or version bump) |
| 5 | **No modification timestamps** — "Timestamps 'N/A' per FAT32 short-name limitation" (march-m25 F2, claim 0434); STAT as merged is `[size u64le][type u8]` — **no mtime** | — | ❌ **GAP** — the scoping doc promised STAT = size/type/**mtime**; the landed op serves size+type only. The file manager's properties panel still shows "N/A" for dates. Needs an additive STAT bump |
| 6 | **Content-pool exhaustion / silent empty reads** — files listed but never content-loaded (`len=0`) when the 8192-B pool overflows → history recall no-op + clobbering (claim 6344) | HF4/HF5 (apps + user data leave the ESP window) | 🔶 open — HF4 landed (apps off the ESP); the class dies for good when HF5 moves user data out |
| 7 | **kstack pressure from FAT staging** — 2×2048 staging + FAT buffers overflowed the 8 KiB kstack (m13 log) | HF6 (fat.zig deleted) | 🔶 open |
| 8 | **Image-rebuild iteration loop** — ~50 apps baked into the ESP; rebuild the image to test an app | HF4 | ✅ merged — drop-`.ELF`-and-exec (PR #769, claim 7599) |
| 9 | **Disk image bloat / ceremonies** — 128 MiB image, 36 MiB DATA partition, expanding/resizing | HF6 | 🔶 open |
| 10 | **Per-gate writable image copies + shared-disk locks** (`gate_shared_disk_lock` contention) | HF6 (one shared read-only boot image) | 🔶 open |
| 11 | **virtio-blk reset at ExitBootServices** — post-MMU queue re-arm footgun (claim 6420) | HF6 (post-exit blk path deleted) | 🔶 open |
| 12 | **8.3 path normalization / prefix routing complexity** (`/esp` vs `/data`, traversal defense, case folding — march-m10 F2) | HF5/HF6 (path canon re-pointed, fat deleted) | 🔶 open |

**Bottom line:** the read-side pain is dead (HF1/HF2). The write-side caps
die at the channel but **live on in the syscall ABI until HF5**. Two pain
points (long names, mtime) are **not covered by any merged card** and should
be decided before HF5 lands — either fold an mtime/name-widening wire
revision into HF5 or file them as follow-up cards, or the "timestamps N/A"
and truncated-name behaviors quietly become permanent.

## Code processing / in-guest Zig compiler (self-hosting lane 2, #708)

The "keep progressing" thread. Core landed; the issue and the GUI consumer
are the open end.

- **Landed (claim 0098, antigravity):** `user/src/lib/asmenc.zig` (encoder
  extraction, VL1), widened assembler set (VL2), `user/src/zc.zig` tokenizer
  + recursive-descent parser + codegen (VL3/VL4), `exec ZC.BIN` in-guest
  compile → ELF32 the loader runs (VL5, `verify-live-zc.sh` PASS 1/1,
  exit 72 observed). Subset: `fn` with typed params, let/const, if/else,
  while, return, calls, block scoping, int/bitwise/compare/logical exprs,
  `svc` builtins for write/exit/file ops. Bounded: ≤32 functions, ≤512
  lines, zero heap.
- **Open (issue #708, milestone #20): re-scoped 2026-09-01.** VL1–VL5 are
  closed out with evidence (claim 0098); #708 now carries **VL6 (GUI
  consumer) only** — the win/draw svc builtins (win_open/fill/present) —
  and **depends on #749 (Z0.5, the dialect contract)**: the first GUI app is
  written in the honest dialect, so VL6 lands right after (or paired with)
  Z0.5. The future of Lane 2 beyond that is the ladder: Z1a–Z4b filed as
  #750–#761.
- **Sibling lanes (milestone #20):** #706 Lane 0 hygiene — **split 2026-09-01
  into four parallel cards**: #773 (re-verify live-desktop + gate-inventory),
  #774 (live-asm/disas fixture drift), #775 (M20 tabs probe-decode red),
  #776 (VZ CI wiring); #706 is now the umbrella — and #707 Lane 1 window
  depth (WM1–WM4: window ceiling 4→8 via page-pool back-buffers, mission
  control, taskbar depth) — all OPEN, unclaimed. (#707 note: M33's userland
  composition may supersede WM1's kernel page-pool framing — check before
  claiming.)

### The leveled Zig support ladder (Z0.5 → Z4, step-at-a-time)

> Aspirational plan (2026-09-01): split the "Zig in the system" dream into
> steps so each is independently claimable and honestly gated. The target
> is concrete — **this repo is pinned to Zig 0.16.0** (`.zigversion`,
> `minimum_zig_version = "0.16.0"`), so "Zig 0.16 support" means the
> in-guest compiler reaches parity with the language the host project is
> written in. Full 0.16 conformance (comptime, std, error sets) is a
> research project; the ladder makes the *dialect* the goal, with a real
> gate at the top: **a `.z` source in the shared subset compiles on host
> `zig 0.16` AND in-guest `zc`, and behaves the same.** That's testable.
>
> Two facts from the current code decide the order (observed, claim 0098):
> (1) the gate source is `fn main() void { svc(3, 72); }` — **`svc` is a
> zc keyword, NOT valid Zig 0.16**; (2) `build_elf32` emits **code only**
> — there is no data segment, so strings/arrays/structs all need one
> added before they can exist. Every step below is one agent / one PR
> sized (the VL1–VL6 pattern), removes exactly one bound, and its gate
> stays honest.

| Step | Issue | Goal | Gate | Removes / adds |
|------|-------|------|------|----------------|
| **Z0 — Spine** | — (landed, claim 0098) | scalar programs, arithmetic, control flow, `svc` builtins, ELF32 | ✅ **landed** (claim 0098, VL1–VL5); `verify-live-zc.sh` PASS | — (bounds: ≤32 fns, ≤512 lines, 8 KiB code buffer, zero heap, one file) |
| **Z0.5 — Dialect contract** | #749 | make the spine *valid Zig 0.16*: `svc(3,72)` becomes a call through a magic `@import("zc")` prelude (zc resolves it in-guest; a real `zc.zig` shim with `asm volatile ("svc #0"…)` exists on the host), so sources parse under `zig 0.16` | the existing `MAIN.Z` rewritten in the honest dialect **parses + type-checks** under host `zig build-exe -target aarch64-freestanding` (compile-only); in-guest `verify-live-zc.sh` unchanged green | removes: "sources are not Zig" — THE step that makes conformance reachable; every later step writes in the honest dialect |
| **Z1a — Data segment + strings** | #750 | a `.rodata` blob appended to the ELF (same PT_LOAD); `"…"` tokenizes, lands in the blob, evaluates to (addr,len); a write builtin prints it | in-guest: a program prints a string literal byte-exact; host `zig 0.16` parses the same source | adds: data segment (first structural change to `build_elf32`); grows the 8 KiB output buffer (string data consumes it) |
| **Z1b — Arrays** | #751 | fixed-size arrays in BSS/stack; scaled-index ldr/str | fill an array in a loop, write it out byte-exact | adds: index addressing |
| **Z1c — Structs** | #752 | field offsets, member load/store | a two-field struct serialized to bytes | adds: aggregate types + offsets |
| **Z1d — Pointers** | #753 | `&x`, `x.*`, pointer params | swap through pointers; pass buf+len to a fn | adds: address-of/deref, indirect calls (`blr`) groundwork |
| **Z1e — Control-flow depth** | #754 | `for (0..n)` + array iteration (reuse while lowering); `switch` as a cond-chain (jump tables later) | a for-loop sum; a switch mapping an int to a string | adds: range/array iteration, multi-way branch |
| **Z1f — Enums** | #755 | tagged constants, cast to/from int | an enum-valued switch, run green | adds: enum type |
| **Z2a — Heap** | #756 | `sys_mmap` (M29 anonymous) + a bounded bump arena exposed through the prelude | read a file, build a string in heap, write it back byte-exact | removes: zero-heap bound |
| **Z2b — defer + fn pointers** | #757 | scope-exit cleanup lowering; `blr` through a function pointer | a program using both, run green | adds: cleanup + indirect calls |
| **Z3a — Multi-file compile** | #758 | `zc a.z b.z out.elf`, cross-file symbol table | two files, cross-file call, run green | removes: one-source-file bound |
| **Z3b — stdz subset** | #759 | fmt (u64→dec/hex), string builder, ring buffer in `lib/`, compiled in | a stdz-using program ships as an app | adds: the first reusable library |
| **Z4a — Corpus parity (compile)** | #760 | a fixture corpus of `.z` sources; every source compiles with host `zig 0.16` (compile-only) AND guest `zc` (compile + run), behavior pinned | corpus green on both sides | the "dual-compile" gate, made real |
| **Z4b — Behavioral parity (run)** | #761 | where host 0.16 output can run — needs a **host link contract** (linker script + target recipe; the loader is already ELF64-class-agnostic, so no kernel seam) — byte-equivalent behavior | dual-run comparison on the contract | the top of the ladder; explicitly a negotiation, not assumed |

**Honest notes on the ladder:**

- **Z0.5 is the real unlock.** The `svc` keyword means today's `.z` sources
  are *Zig-ish*, not Zig — every feature added before the dialect is made
  honest bakes in more non-Zig syntax that conformance later has to unwind.
  The magic-import trick (`@import("zc")` resolved by the compiler
  in-guest, shimmed by a real `zc.zig` on the host) is small and proven
  (Zig's own `@import("std")` is the same shape), and it makes every later
  step's gate "host parses it" instead of "host rejects it, trust us".
- **The 8 KiB code buffer is a wall.** Z1a's string data + arrays + structs
  will consume it fast; growing the output bound (8 → 32 KiB, or
  segment-based) should ride along with Z1a, not wait.
- **The loader is already ELF64-class-agnostic — the wall is the layout
  contract.** Verified 2026-09-01: `kernel/src/elf.zig` accepts `ei_class`
  1 *or* 2, and `mkdyn-elf.py` already emits ELF64 `.SO` files. What host
  `zig 0.16` output actually violates is the fixed base `0x00400000` (host
  emits `0x1000000`), the ≤2-PT_LOAD rule (host emits 3), the ≤256 KiB
  image cap (a trivial program measures ~283 KiB with debug info), and
  entry-0 (needs `export fn _start`). So Z4a's gate is deliberately
  *compile-only* on the host (parse + type-check), and full dual-*run*
  parity (Z4b) needs a **host link contract** — linker script + target
  recipe — negotiated on its own, not a kernel seam. That's the honest
  answer to "how realistic is 0.16": dialect parity yes, run-parity only
  with the link contract.
- **VL6 (the GUI consumer, #708) pairs with Z0.5 (#749).** It's svc-builtin
  work (win_open/fill/present) — no new language features. Land the dialect
  re-shape and the win builtins together, so the first GUI app is written
  in the honest dialect instead of the keyword dialect.
- **Z1e and Z1f can pair** in one claim if reviewers prefer — they're both
  statement-lowering; the split is for single-agent sizing.
- **The corpus accumulates from day one.** Every Z step ships its
  `tests/zc-corpus/<step>.z` fixture with the step (declared in Touches), so
  Z4a only adds the runner + pins behavior instead of rewriting history.
- **zc.zig is a single-editor file.** Every Z step touches it; the gate
  already rejects overlapping ACTIVE claims, but plan Z work strictly
  one-at-a-time (Z1e+Z1f may pair) so claims never trip it.

**Suggested sequencing:** land **#749 (Z0.5)** first — it's the dialect
unlock and the host-shim contract is pinned in its body — then **#708 (VL6)**
rides right after (or paired with it, per the ladder note). Then claim Z1a
(#750) and on down the ladder; the Z4a corpus is already accumulating from
Z0.5 (each step ships its fixture), so it's warm when it lands. Lane 0's
four cards (#773–#776) are independent and claimable in parallel with any
of the above.

## Other open GitHub threads

| Thread | Milestone | Open cards | Notes |
|--------|-----------|-----------|-------|
| Sexiburger god menu | #19 (6 open) | #701–#705 + umbrella #677 | action registry seam → menu shell → type-to-filter → test-app registration → covenant-of-six |
| Self-hosting seed | #20 (20 open) | #706 umbrella (0a–0d → #773–#776) · #707 · #708 (VL6, depends #749) + ladder **#749–#761** | see above; umbrella #620 closed |
| WASM core interpreter | #22 **proposed** (5 open) | **#762–#766** (W1–W5) | one interpreter, the whole ecosystem: host-built wasm apps run in-guest; module = data via the file channel (no ELF contract); `env.*` imports → ADR 0007, no WASI; tracker `docs/wasm-core-scoping.md` |
| M33 seam B (pixel ownership) | #17 ✅ closed 2026-09-01 | — | SB1–SB6 all landed (claims 7418/8878/3633/2382/7397/6864); SB6's yield-spin scheduler finding filed as #768 |
| Bug cards (unmilestoned) | — | #729–#734 | P1 #729 (desktop launch err=6 ENOENT regression), P2 #730 (WND.BIN abort), P2 #732 (broken win harness), P3 #731/#733/#734 (stale chrome, dhcp fixture, glyph shift) |

## Suggested claim order when M34 finishes

1. **HF5** (user-data migration) — the big one; fold the **mtime + name
   width** wire revision in here (gaps #4/#5) or file them separately.
2. **#749 (Z0.5) → #708 (VL6)** — the compiler thread's open end,
   independent of M34.
3. **HF6** (FAT removal) — after HF5; deletes pain points #2/#6/#7/#9–#12
   at the root.
4. **HF7** (CLONE dedup) — parallel, worktree capstone.
