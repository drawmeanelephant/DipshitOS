# Multi-agent concurrency gameplan — who touches what, and when

Date: 2026-09-01 · Sources: open board (milestones #19/#20/#21/#22), the
Touches declarations in open `claim` issues on the GitHub tracker, and the
coordination rules (`AGENTS.md`). The goal: push several agents on several projects at once
without the merge-time asshole — i.e. without two PRs fighting over the same
file. **The coordination gate already enforces this mechanically** (two
ACTIVE claims declaring overlapping Touches fail CI); this doc is the plan
that keeps that from happening in the first place.

## The three rules that make concurrency safe

1. **Disjoint Touches = parallel.** Two claims whose file sets do not
   intersect can run at any time, on any schedule. Everything below is
   grouping cards into lanes with disjoint Touches.
2. **One agent per hot file at a time.** The files below are touched by
   nearly every card in their area; only one lane may hold them at once.
   Whoever claims last waits or merges through the integration branch.
3. **HF6 is the serialization point.** It deletes `fat.zig` and rewrites
   every class-B gate script — nothing else in the kernel/gate area may
   land while it is ACTIVE.

## Hot-file map (the merge-time assholes)

| File | Held by (today) | Serializes with | Notes |
|------|-----------------|-----------------|-------|
| `kernel/src/exec.zig` | HF4 (app delivery) | #729 (desktop launch ENOENT) | #729 should ride HF4's lane — same file, same path |
| `kernel/src/fat.zig` | HF5/HF6 (migration/removal) | HF5 → HF6 | strictly sequential inside M34 |
| `kernel/src/monitor.zig` | vf commands (landed) | HF5 (`/data` deprecation) · W2 (`wasm` cmd) | only one monitor-command card at a time |
| `host/.../VMRunner/main.swift` | HF4–HF7 (share serving) | #731/#732 (win-harness fixes) | M34 owns it until HF7; bug lane waits |
| `build.zig` | app-embedding (every lane) | W1 (WASM.BIN) · Z-ladder corpus · Sexiburger apps | **one app-embedder at a time** — the single most contended file |
| `image/mkfat32.py` + `make-image.sh` | HF6 (slim) | any card adding apps | HF6 must be last in M34 |
| `docs/status.md` | everyone (rows) | merge-time only | append rows, never rewrite others' rows |
| `docs/hardware-contract.md` | M34 wire | M35 W1 contract | one wire-author at a time |
| `tests/transcript-console.txt` | help-line additions | W2 (`wasm` help) · HF5 (mount deprecation) | serialized with monitor.zig |
| `tools/lib/gate-run.sh` | HF6 (fleet) | every live gate | frozen while HF6 is ACTIVE |
| `user/src/zc.zig` / `asmenc.zig` | Z-ladder only | — | **private to the compiler lane** — fully parallel |
| `user/src/wasm.zig` | W-lane only (new file) | — | **private to the WASM lane** — fully parallel |

## Lanes and the schedule

### Lane M — M34 FAT-free (the FS agent's thread)
`HF4 → HF5 → HF6 → HF7` in order, one agent. Owns exec.zig, fat.zig,
main.swift, the vf gates, then the fleet. **Fold #729 in with HF4** (same
file, same exec path — the desktop ENOENT is a sys_exec regression and HF4
rewrites that path).

### Lane C — Compiler ladder (self-hosting, #708 + #749–#761)
Private files (`zc.zig`, `asmenc.zig`, `verify-live-zc.sh`) — **parallel
with everything** except build.zig. Claim Z0.5+VL6 now; continue Z1a→Z4b as
each lands. Build.zig footprint is zero (ZC.BIN already ships) — keep it
that way; put corpus fixtures under `tests/`, not build.zig.

### Lane W — WASM (M35, #762–#766)
`user/src/wasm.zig` is a brand-new file — **parallel with everything**.
Order within the lane: W1 (no shared files beyond build.zig for WASM.BIN)
→ W2 (takes monitor.zig + transcript — serialize against HF5's deprecation
line) → W3–W5 (private + virelai shims).

### Lane S — Sexiburger (#677, #701–#705)
Userland menu + action registry — new userland files, no kernel. Parallel,
**except build.zig** (app embedding) and any ui.zig shape it shares with
apps. Wait for W1's build.zig slot if contested.

### Lane B — Bug fixes (#729–#734, #768)
- **#733/#734** (gate fixtures: dhcp pong, glyph decode) — gate-script-only,
  fully parallel now.
- **#729** — rides HF4 (exec.zig).
- **#731/#732** (win-harness: runner `--script` path, stale chrome) — wait
  for main.swift to free up after HF4/HF5.
- **#730** (WND.BIN abort) — compositor-area; M33 is closed so it's free;
  parallel with everything except anything touching `driving_award.zig`
  (nothing active does).
- **#768** (yield-spin scheduler stall — filed 2026-09-01 from the SB6
  finding) — scheduler/timer; parallel now.

## Suggested wave (what to do when)

| Wave | Lane M (FS) | Lane C (compiler) | Lane W (WASM) | Lane S (sexiburger) | Lane B (bugs) |
|------|-------------|-------------------|---------------|---------------------|---------------|
| **1 (now)** | HF4 (+#729) | Z0.5+VL6 | W1 | #701/#702 (registry + shell — no build.zig yet) | #733, #734, #768 |
| **2** | HF5 | Z1a | W2 (after HF5's monitor edit) | #703+ (menu shell, type-to-filter) | — |
| **3** | HF6 (alone — fleet) | Z1b+ | W3–W4 | #704/#705 (test-app reg, covenant) | #730, #731/#732 (after main.swift frees) |
| **4** | HF7 | Z2a+ | W5 (capstone — needs HF4's app delivery) | — | — |

Wave 1 is the answer to "push multiple agents now": **five lanes, zero
overlapping Touches**, as long as build.zig has exactly one holder (give it
to W1 or Sexiburger — not both — and the other defers app embedding one
wave).

## The discipline that keeps it honest

- Every claim's Touches must be exact and complete — the gate is only as
  good as the declarations. A wrong Touches is how merge-time assholes
  happen despite the gate.
- `docs/status.md`: append/update your own milestone's row only; never
  rewrite another lane's row. Merge-time conflicts here are cosmetic and
  expected — resolve by taking the union, not by reverting.
- Index tables regenerate at merge (bot-owned) — never commit index churn
  from a branch.
- When two lanes genuinely need one file (monitor.zig for HF5 vs W2),
  the *second* claimant waits or merges through the integration branch —
  the repo's stated rule, and it's the one that actually prevents the
  asshole.

## What this sweep added / fixed (2026-09-01)

- **Filed #768** — the SB6 yield-spin scheduler finding (M33 was closed
  without a card for it).
- **Closed milestone #17 (M33)** — SB1–SB6 all landed; 10/10 issues.
- **Fixed status.md** — M33 row → ✅ done; M34 row → 🔄 in progress
  (HF1–HF3 merged, not "proposed").
- **Noted for later:** #507 E6 console split (Ctrl+backtick) is still
  deferred and valid — it's referenced from #706 Lane 0 as optional; and
  the roadmap's documented exclusions (accessibility, USB mass storage/
  serial) remain future work, untouched.
