# Claim: M35 W3 — import breadth — the frozen env.* surface + wasm window/file apps (#764)

- **Owner:** buffy (`freebuff/okay-shower-thoughts-here-we-re-using-fat32-for-so-b0ce3067-2b04-4b81-984d-9fd76bfcf123`)
- **Prompt / plan:** Dispatch the FULL frozen env.* surface from `docs/wasm-import-contract.md` (W1a #778, merged PR #786) in the interpreter — file 23–27 + 34–37, win 12–20, audio 42–45, timers 40/41, mmap 63 (+ munmap 64, same contract row), procs 7, wait 8 — with validation-time rejection of anything outside the frozen set, the `virelai.h`/`virelai.zig` host-author shims, and two live proof apps: a wasm window app (fill observed via the scanout capture) and a wasm file app (byte-exact read through the HF4 share).
- **Scope:** the interpreter's import surface + validation + shims + the W3 live-gate phases. Out: floats (W4 #765), the `wc` capstone (W5 #766), the event pump for timer delivery (contract §5.4 — imports dispatch; delivery extends by ADR), Go/WASI (post-M35), everything not in the contract (§6).
- **Touches:** user/src/wasm.zig (frozen-table validation, svcN wrappers, 30-arm dispatch, capture seam, tests), tests/virelai.h + tests/virelai-probe.c + tests/winapp.c + tests/fileapp.c (new), tools/verify-virelai-probe.py (new), build.zig (shim-check step), tools/verify-live-wasm.sh (W3 phases), user/src/wasm-corpus/winapp.wasm + fileapp.wasm (new pinned fixtures), docs/claims/3456-w3-import-breadth.md, docs/logs/freebuff-20260901-008.md
- **Depends on:** W2 #763 merged (PR #796); W1a #778 contract (PR #786)
- **Heartbeat:** 2026-09-01 (re-verified 2026-09-01 after HF6 rebase)
- **Status:** 🔄 in progress — class-A green, ready for PR

## Notes

Gate: `zig test user/src/wasm.zig` **20/20** (13 W1b/W2 + 7 W3); `zig build shim-check` PASS (the probe's import table is exactly the frozen 30, class-A acceptance item); `tools/verify-live-wasm.sh` W2+W3 phases PASS on VZ (macOS 27 arm64 local run) — hello regression + wasm window app (fill observed in the scanout capture at rect=100,100,96,48, EINVAL mapping `win_set_visible(id,2) → -1` proven THROUGH the stack, exit 21) + wasm file app (FILE.TXT echoed byte-exact via env.write, exit status = 512 = file size). Default boot unchanged; zero new syscall slots. Rebased onto origin/main through HF6 (fat deletion) — kernel delta now exactly one file_table clamp fix (claim 3456 gate finding: vf READ carry > out_buf smashed staging) plus the W3 interpreter; 2026-09-01 re-verified: `zig test` 20/20, `shim-check` PASS, `zig build`/`image`/`wasm` (55200 B, 24576/30576/152728), `verify-coordination`/`bss-budget` PASS, deterministic fixture rebuilds byte-identical (`winapp 603dc2ab`, `fileapp 9f31d07e`).

### The frozen surface, implemented exactly as §5

- **Validation (contract §1):** every import must be `env.*` from the frozen table WITH the contract signature; `UnknownImportModule` (e.g. `wasi_snapshot_preview1.fd_write` — WASI always fails validation), `UnknownImport` (ad-hoc names), `ImportSignature` (known name, wrong shape) — all rejected BEFORE start. The `frozen_imports` table is the single source of truth shared by the validator.
- **Dispatch:** one arm per name (29 §5 + the W2 write/exit pair). Pointer args range-checked against `memory.size` BEFORE any kernel copy (contract §3 — OOB traps `bounds`, never an EFAULT at svc); zero-length slices are valid at any ptr; `dir_list` (40-byte DirEntry rows), `win_get` (16 B), `win_query` (32 B), `audio_info` (16 B AudioInfo), `procs` (40-byte rows) all copy with the §5 shapes.
- **svcN seam:** one generic `svc #0` helper (x8=slot, x0..x5) covers all 20 new wrappers; errno mapping is the kernel's (contract §4) — the live negative-path proof: `win_set_visible(id,2)` returns exactly −1 in-guest.
- **max_imports 16 → 32** (+640 B Module — measured, in the BSS after-file).
- **Guest footprint:** text 24,576 / data 30,576 / bss 145,528 ≈ 196 KiB staged — inside the 256 KiB loader budget (before/after in artifacts/bss-w3-{before,after}.txt). The capture seam is host-test-only (null pointer in the guest — zero guest BSS).

### Shims (acceptance item: "virelai.h compiles a host program against the contract alone")

`tests/virelai.h` declares all 30 imports with `import_module("env")`/`import_name(...)` attributes + the MODE_*/PROT_*/MAP_* constants + `v_dirent` (40 B) / `v_audio_info` (16 B) with `_Static_assert`s. `tests/virelai-probe.c` references EVERY import; `zig build shim-check` compiles it (`zig cc -target wasm32-freestanding -nostdlib -fno-sanitize=undefined -g0`) and `tools/verify-virelai-probe.py` asserts the import table is EXACTLY the frozen 30 (set-matched — clang emits imports in its own order, which is linker-defined and irrelevant).

### Live fixtures (pinned, deterministic)

`winapp.wasm` sha256 `603dc2ab19a9aca1e7ad4fe23eb4c277c526c2bd2802b2fc0721a486dde06d3e` (982 B) / `fileapp.wasm` `9f31d07ec306d10eada0391e2ece92d92b21012fd71a2fdd90b24b9f62147c7c` (767 B) — committed, byte-identical to fresh `zig cc -target wasm32-freestanding -nostdlib -fno-sanitize=undefined -g0` rebuilds with fixed output basenames (the W2 determinism recipe: `-g0` strips DWARF source-path leakage; the name custom section embeds only the output basename). Re-verified by host test `w3: live-gate app fixtures parse + validate against the frozen surface`, by the shim pins in the gate (603dc2ab/9f31d07e), and by the positive path in the live run. (W5's `wc` can reuse the recipe.)

### Real bugs caught by the clang-generated modules

- The generator's first fixtures omitted the vec-count bytes in the type/import sections (parse desync — `UnknownValueType` at the type tag); regenerated with counts. (Fixture bug, not interpreter bug — but it earned a python reader sanity pass.)
- `@bitCast` size discipline in 0.16: i32→u64 needs an explicit `u32` bitcast + widen (`argU64` helper), not a direct bitcast.
- `std.mem.allEqual` takes (T, slice, scalar) — call sites fixed.

### Documented deviations (none — scope discipline)

- munmap (slot 64) IS dispatched: the contract's §5.5 row gives the interpreter this shape ("the interpreter exposes it with this shape so the virelai.h heap can free arenas"); the ISSUE's "mmap 63" wording is narrower but the contract table is normative and the pair ships together. Noted in the PR body.
- Timer/event delivery pump is NOT built (contract §5.4 explicitly defers it; imports dispatch — the live apps don't use timers).
- The CLI inventory (docs/archive/gate-inventory-detail.md) is curated — live-zc/vf/sb2/sb3 are not registered either; the gate script + claim + issue are the record, per lane precedent.

Claim id derivation: `bash tools/status/claim-id.sh "freebuff/okay-shower-thoughts-here-we-re-using-fat32-for-so-b0ce3067-2b04-4b81-984d-9fd76bfcf123" w3-import-breadth` → **3456** (the backticked owner branch, NOT the `buffy (…)` display prefix — claim 7188's CI catch).