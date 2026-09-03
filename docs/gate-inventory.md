# VirelaiOS verification gate inventory

> Canonical classification of every verification command. **A green GitHub CI
> badge proves class A only** — it says nothing about the Apple-silicon
> Virtualization.framework hardware gates (class B), interactive gates (C), or
> diagnostics (D); run the class-B set with `just verify-vz` on real hardware.
> Per-gate pass/fail status lives in [`docs/status.md`](status.md); full
> per-gate evidence paragraphs, claim numbers, and the machine-readable
> `GATE` records live in
> [`archive/gate-inventory-detail.md`](archive/gate-inventory-detail.md)
> (issue #265).

## Classes

- **A — portable / build CI.** Deterministic, no Apple silicon, no VZ VM.
  Runs in GitHub CI (`.github/workflows/ci.yml`) and as `just verify-portable`.
  A green CI badge means exactly these passed and nothing else.
- **B — Apple-silicon Virtualization.framework hardware gate.** Boots a real
  VZ VM on Apple silicon. GitHub-hosted CI does **not** run these and cannot
  prove them; run `just verify-vz` on a development host.
- **C — interactive / manual hardware gate.** Requires a human at the
  keyboard. Not automatable, not in CI.
- **D — diagnostic experiment** (claims 0017/0018/0020/0021/6460/7896);
  **not an acceptance gate**. Passing a diagnostic proves nothing about the
  milestone.

## Gate table

One row per gate; the command cell is the exact gate command. Gates from
completed milestones (M3–M16) are compressed to name / command / status /
last-verified — assertion detail and evidence paragraphs are in the archive.
**Active/upcoming gates (M17+) register here in full detail** at their
card's close-out and graduate to the archive when their milestone closes.

| ID | Class | Command | Status | Last verified |
|----|-------|---------|--------|---------------|
| `fmt` | A | `zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig` | ✅ pass | every CI push |
| `unit-tests` | A | `bash tools/verify-unit-tests.sh` | ✅ pass | every CI push |
| `glyph-raster` | A | `bash tools/verify-glyph-raster.sh` | ✅ pass | every CI push |
| `mutations` | A | `bash tools/verify-mutations.sh` | ✅ pass | every CI push |
| `transcript-mock` | A | `zig build test-console` | ✅ pass | every CI push |
| `guest-build` | A | `zig build` | ✅ pass | every CI push |
| `image-build` | A | `zig build image` | ✅ pass | every CI push |
| `inspect` | A | `zig build inspect` | ✅ pass | every CI push |
| `swift-runner-build` | A | `swift build --package-path host/vm-runner` | ✅ pass | every CI push |
| `swift-spike-build` | A | `swift build --package-path host/vm-runner -Xswiftc -DSPIKE` | ✅ pass | every CI push |
| `context` | A | `zig build context` | ✅ pass | every CI push |
| `coordination` | A | `bash tools/status/verify-issue-coordination.sh` | ✅ pass | every CI push |
| `coordination-tooling` | A | `bash tools/status/test-coordination.sh` | ✅ pass | every CI push |
| `workflow-lint` | A | `bash tools/lint-workflows.sh` | ✅ pass | every CI push |
| `mmu-debt` | A | `bash tools/verify-mmu-debt.sh` | ✅ pass | every CI push |
| `bss-budget` | A | `bash tools/verify-bss-budget.sh` | ✅ pass | every CI push |
| `verify-portable` | A | `just verify-portable` (aggregate — the full class-A set) | aggregate | every CI push |
| `bad-handoff` | B | `bash tools/verify-bad-handoff.sh` | ✅ pass | 2026-08-06 |
| `marker` | B | `bash tools/verify-marker.sh` | ✅ pass | 2026-08-07 |
| `nvram-console` | B | `bash tools/verify-nvram-console.sh` | ✅ pass | 2026-08-07 |
| `host-console-pty` | B | `bash tools/verify-host-console.sh` | ✅ pass | — |
| `serial-takeover` | B | `zig build run` | ✅ pass | 2026-08-08 |
| `live-transcript-rx` | B | `bash tools/verify-live-transcript.sh` | ✅ pass | 2026-08-08 |
| `live-help` | B | `bash tools/verify-live-help.sh` | ✅ pass | 2026-08-15* |
| `live-exceptions` | B | `bash tools/verify-live-exceptions.sh` | ✅ pass | 2026-08-08 |
| `live-timer` | B | `bash tools/verify-live-timer.sh` | ✅ pass | 2026-08-09 |
| `live-tasks` | B | `bash tools/verify-live-tasks.sh` | ✅ pass | 2026-08-09 |
| `live-userspace` | B | `bash tools/verify-live-userspace.sh` | ✅ pass | 2026-08-09 |
| `live-svc` | B | `bash tools/verify-live-svc.sh` | ✅ pass | 2026-08-10 |
| `live-uaccess` | B | `bash tools/verify-live-uaccess.sh` | ✅ pass | 2026-08-10 |
| `live-addrspaces` | B | `bash tools/verify-live-addrspaces.sh` | ✅ pass | 2026-08-10* |
| `live-lifecycle` | B | `bash tools/verify-live-lifecycle.sh` | ✅ pass | 2026-08-10* |
| `live-exec` | B | `bash tools/verify-live-exec.sh` | ✅ pass | 2026-08-10 |
| `live-procs` | B | `bash tools/verify-live-procs.sh` | ✅ pass | 2026-08-11* |
| `live-args` | B | `bash tools/verify-live-args.sh` | ✅ pass | 2026-08-11* |
| `live-concurrent` | B | `bash tools/verify-live-concurrent.sh` | ✅ pass | 2026-08-11* |
| `live-long-lived` | B | `bash tools/verify-live-long-lived.sh` | ✅ pass | 2026-08-11* |
| `live-kill` | B | `bash tools/verify-live-kill.sh` | ✅ pass | 2026-08-11* |
| `live-ipc` | B | `bash tools/verify-live-ipc.sh` | ✅ pass | 2026-08-11* |
| `live-scale` | B | `bash tools/verify-live-scale.sh` | ✅ pass | 2026-08-11* |
| `live-procs-syscall` | B | `bash tools/verify-live-procs-syscall.sh` | ✅ pass | 2026-08-11* |
| `live-wait` | B | `bash tools/verify-live-wait.sh` | ✅ pass | 2026-08-11* |
| `live-sleep` | B | `bash tools/verify-live-sleep.sh` | ✅ pass | 2026-08-10 |
| `live-entropy` | B | `bash tools/verify-live-entropy.sh` | ✅ pass | 2026-08-11* |
| `live-reboot-shutdown` | B | `bash tools/verify-live-reboot.sh` | ✅ pass | 2026-08-08 |
| `live-fs` | B | `bash tools/verify-live-fs.sh` | ✅ pass | 2026-08-09 |
| `live-gfs` | B | `bash tools/verify-live-gfs.sh` | ✅ pass | 2026-08-11* |
| `live-net-tx` | B | `bash tools/verify-live-net-tx.sh` | ✅ pass | 2026-08-11 |
| `live-net-rx` | B | `bash tools/verify-live-net-rx.sh` | ✅ pass | 2026-08-11 |
| `live-net-arp` | B | `bash tools/verify-live-net-arp.sh` | ✅ pass | 2026-08-11 |
| `live-net-icmp` | B | `bash tools/verify-live-net-icmp.sh` | ✅ pass | 2026-08-11 |
| `live-net-udp` | B | `bash tools/verify-live-net-udp.sh` | ✅ pass | 2026-08-11 |
| `live-net-udp-syscall` | B | `bash tools/verify-live-net-udp-syscall.sh` | ✅ pass | 2026-08-24* |
| `live-net-nat` | B | `bash tools/verify-live-net-nat.sh` | ✅ pass | 2026-08-12 |
| `live-net-dhcp` | B | `bash tools/verify-live-net-dhcp.sh` | ✅ pass | 2026-08-24* |
| `live-net-dhcp-renew` | B | `bash tools/verify-live-net-dhcp-renew.sh` | ✅ pass | 2026-08-24* |
| `live-net-dhcp-autonomous` | B | `bash tools/verify-live-net-dhcp-autonomous.sh` | ✅ pass | 2026-08-24* |
| `live-net-tcp` | B | `bash tools/verify-live-net-tcp.sh` | ✅ pass | 2026-08-12 |
| `live-net-tcp-rto` | B | `bash tools/verify-live-net-tcp-rto.sh` | ✅ pass | 2026-08-24* |
| `live-screen` | B | `bash tools/verify-live-screen.sh` | ✅ pass | 2026-08-13* |
| `live-text` | B | `bash tools/verify-live-text.sh` | ✅ pass | 2026-08-13* |
| `live-roadpops` | B | `bash tools/verify-live-roadpops.sh` | ✅ pass | 2026-08-13* |
| `live-glyphs` | B | `bash tools/verify-live-glyphs.sh` | ✅ pass | 2026-08-14 |
| `live-win` | B | `bash tools/verify-live-win.sh` | ✅ pass | 2026-08-13* |
| `live-win-syscall` | B | `bash tools/verify-live-win-syscall.sh` | ✅ pass | 2026-08-13* |
| `live-win-close` | B | `bash tools/verify-live-win-close.sh` | ✅ pass | 2026-08-13* |
| `live-win-move` | B | `bash tools/verify-live-win-move.sh` | ✅ pass | 2026-08-13* |
| `live-xhci` | B | `bash tools/verify-live-xhci.sh` | ✅ pass | 2026-08-13* |
| `live-usb` | B | `bash tools/verify-live-usb.sh` | ✅ pass | 2026-08-13* |
| `live-input` | B | `bash tools/verify-live-input.sh` | ✅ pass | 2026-08-13* |
| `live-input-depth` | B | `bash tools/verify-live-input-depth.sh` | ✅ pass | 2026-08-15 |
| `live-editing` | B | `bash tools/verify-live-editing.sh` | ✅ pass | 2026-08-15* |
| `live-win-hig` | B | `bash tools/verify-live-win-hig.sh` | ✅ pass | 2026-08-15* |
| `live-pointer-cg` | B | `bash tools/verify-live-pointer-cg.sh` | ⚠️ open — self-gates on Accessibility trust; class-B pass unachieved, card U4 stays class-C | 2026-08-16 |
| `live-pointer-virtio` | B | `bash tools/verify-live-pointer-virtio.sh` | ✅ pass — headless pointer injection over custom-virtio queue 3 (claim 9367); #151's focus proof upgraded to class-B-headless, no trust needed on this path | 2026-08-24 |
| `live-virtio-e2e` | B | `bash tools/verify-live-virtio-e2e.sh` | ✅ pass — #523 acceptance row: injected input in, structured console + framebuffer snapshot out over the custom-virtio control plane, headless (claim 0680); no CGEvent synthesis, no screenshot scraping in the critical path | 2026-08-24 |
| `live-settings` | B | `bash tools/verify-live-settings.sh` | ✅ pass | 2026-08-15* |
| `live-events` | B | `bash tools/verify-live-events.sh` | ✅ pass | 2026-08-15* |
| `live-user-fs` | B | `bash tools/verify-live-user-fs.sh` | ✅ pass | 2026-08-15* |
| `live-desktop` | B | `bash tools/verify-live-desktop.sh` | 🔴 pre-existing red — CALC window 512x424 > back-buffer cap 384 (595bc71 vs 19a6335); migration itself landed | 2026-08-24* |
| `live-sys-kill` | B | `bash tools/verify-live-sys-kill.sh` | ✅ pass | 2026-08-24* |
| `live-m16-image` | B | `bash tools/verify-live-m16-image.sh` | ✅ pass | 2026-08-24* |
| `live-m16-guards` | B | `bash tools/verify-live-m16-guards.sh` | ✅ pass | 2026-08-24* |
| `live-m16-resources` | B | `bash tools/verify-live-m16-resources.sh` | ✅ pass | 2026-08-24* |
| `live-m16-composition` | B | `bash tools/verify-live-m16-composition.sh` | ✅ pass | 2026-08-24* |
| `live-net-offline` | B | `bash tools/verify-live-net-offline.sh` | ✅ pass — M26 N13+N14: offline/no-route fast-exit preflight in PING.BIN/FETCH.BIN (claim 8852); 24/24 across offline boot, no-route boot, online control | 2026-08-28 |
| `cvc-echo` | B | `bash tools/verify-cvc-echo.sh` | ✅ pass | 2026-08-24 |
| `verify-vz` | B | `just verify-vz` (aggregate — every class-B gate above) | aggregate | 2026-08-19 |

\* A bare date is the gate's own recorded PASS date; `date*` is the closing
date of the introducing milestone. Claim numbers per gate are in
[`archive/gate-inventory-detail.md`](archive/gate-inventory-detail.md).
`—` = no individual date recorded; all class-B gates were green in the
M16-close `verify-vz` sweep (see `docs/status.md`).

Non-gate registers (full records in the archive):

- **Class C (interactive):** `console` (`zig build console`) ·
  `pointer-manual` (`bash tools/verify-pointer-manual.sh`, claim 9015 — a
  run without a real mouse FAILs by design).
- **Class D (diagnostics, not gates):** `vz-irq-api-audit`, `preexit-tx`,
  `tx-diag`, `tx-transition`, `fw-mmu-capture`, `t0sz25`, `walk-probe`,
  `t0sz16-walkprobe`.

Notes:

- Raw build steps (`zig build marker`, `nvram-console`, `preexit-tx`,
  `tx-diag`, `bad-handoff`) are classed with their verify script (B or D);
  `zig build kernel` builds artifacts only and is class-A tooling, not a gate.
- Developer tooling (`ragshit`, `just impact`) is not a verification gate.
- `swift-spike-build` runs on GitHub's `xcode-27` public-preview arm64 runner
  (macOS 27 SDK, claim 5844); it compiles the spike, boots nothing, so it
  stays class A.

## Machine-readable records

The fixed-width block (`GATE id=… class=… ci=… apple=… gate=… cmd=…`,
between `<!-- GATE_INVENTORY:START -->` / `END`) moved verbatim to
[`archive/gate-inventory-detail.md`](archive/gate-inventory-detail.md);
CI extracts it from there to list the class-B gates it does not prove.
The dedicated [`VZ hardware gates`](../.github/workflows/vz-gates.yml)
workflow shards the same block across a self-hosted macOS 27+ runner as
a required check — SKIPPED until the repository variable
`VZ_RUNNER_LABEL` names a registered runner (see
[`vz-runner.md`](vz-runner.md)).

## Known flakes (evidence registry)

### Fleet migration 2026-08-24 (claim 5069, issue #528)

Run-isolation migrated most `tools/verify-live-*.sh` to
`tools/lib/gate-run.sh` (private disk/vars/serial per boot) and repaired
the three rot classes from issue #528. Per-gate status after migration:

- **Green under isolation** — every migrated gate not listed below ran
  rc=0 on this host post-migration (evidence: `artifacts/` gate logs).
- **Pre-existing red, reproduced on unmodified origin/main** (detached
  baseline d1dc6fe under /var/folders/.../opencode/baseline-main; cited,
  not masked): `live-win`, `live-win-syscall`, `live-win-close`,
  `live-win-move` ("clock title bar is not amber" pixel family),
  `live-win-hig` (`dui: cycle` missing), `live-asm` + `live-disas` (M22 D4
  fixture drift, "bad entry offset"), `live-calc-prog` AND NOW ALSO
  `live-desktop`: CALC.BIN's window grew to 512x424 in M24 K1-K5 (595bc71,
  PR #482) while driving_award.zig's user back-buffer cap is user_buf_h=384
  (19a6335) — sys_win_open returns invalid for CALC on any boot since
  2026-08-22 (`calc: failed to open window`; newer main surfaces it as
  `desktop: launch CALC.BIN err=6`). Kernel/user constants out of the
  migration's scope; left for the owner. `verify-live-user-fs` (builder
  subset), `live-net-nat` unchanged.
- **Environment-blocked on this agent session** (TCC): `live-screen`,
  `live-text`, `live-glyphs`, `live-roadpops` (Screen Recording),
  `live-pointer-cg` (Accessibility, issue #151) — reproduced identically
  on unmodified main.
- **Host-dependent / flaky, selection supported**: `live-net-nat`
  (`VIRELAI_NET_NAT_RUNS`), net-tcp Run C (`VIRELAI_NET_TCP_RUNS`,
  issue #123 family).
- **Platform finding**: guest FAT writes against freshly-copied images are
  unreliable on this macOS 27.0 host while writes to the long-lived
  `artifacts/disk.img` behave like main; write-gates (fs/gfs/user-fs/
  settings/scripting) therefore boot the canonical image under the
  gate-run.sh mkdir spin-lock instead of copies/overlays.
- **tabs probe-decode race ROOT-CAUSED (claim 2259)**: three stacked
  host-side layers FIXED gate-side (script-expect == screenshot marker made
  the marker capture unreachable — scriptPoll checks the expect first and
  returns; typed-marker triggers fired on the ECHO of forwarded bytes;
  SCK single-shot captures of the non-active window return seconds-stale
  compositions). The walk now parks exit 12 s past the probe marker and
  reads the LAST periodic ladder frame deterministically. REMAINING RED is
  a guest/tools question outside the migration scope: even current frames
  never decode Q{3,}Z (minimal repro: `text put Q\tZ` last-command-only;
  `text` reports cur=4,38 cols=160 cell=8x8; decoded lines lose leading
  glyphs) — suspected tools/decode-screen-glyphs.py grid alignment vs M20
  Lane C's 8px cells (628ab20) or the putraw composite path. Handed to the
  text-layer owners; the gate fails honestly meanwhile.

Existing flake registry rows continue below.

`artifacts/` is gitignored, so per-run evidence is regenerable by re-running
its gate — EXCEPT timing-dependent flakes. Record every known flake here
(append-only; a fix closes the row with a pointer) so a future agent can
tell "documented pre-existing flake" from "new regression".

| Flake | Gate(s) | Symptom | First seen / record | Status |
|-------|---------|---------|---------------------|--------|
| NAT ARP-learn latency | `live-net-tcp` run C (also affects `live-net-nat` runs) | the guest's ARP request for the NAT gateway occasionally times out under live-NAT latency (`learn=0` / an ARP-learn assertion fails) | 2026-08-12, claim 5357 (N11): reproduced on clean main, recorded as not-an-N11-regression; the original capture dir `artifacts/live-net-tcp-arp-flake-baseline/` was local-only and LOST to `.gitignore` — this row is the surviving record (issue #123) | open — see issue #123; re-record evidence under a tracked path when next hit |
| z2a zc-leg OUT.TXT loss | `verify-zc-corpus.sh` case z2a (zc leg) | the in-guest-compiled z2a fixture intermittently (~2/7 boots) exits 72 with `heap-ok` while OUT.TXT comes back empty/missing — the file-channel ops silently failed; the host-built twin was deterministic 7/7 | 2026-09-03, found by the Z4b corpus gate (issue #760/#761); reproduced live + root-caused in claim #899: SMP race — the virtio_file request ASSEMBLY into module-global `vf_req_buf`/`vf_write_buf` ran outside the lock (only submit/wait/free was locked), so the app on the secondary core and the shell's file ops on the primary spliced encodes (host `request length mismatch` refusals) | **FIXED 2026-09-03 (claim #899)**: lock covers encode+exchange in `exchange()`/`write()`; timed-out chains PARKED until their reply is observed (`park_chain`/`reap_parked`); timeout re-kick + retry; wait budget 32M→320M. Verified: z2a zc leg 12/12 PASS (0 mismatches, 7/12 on the secondary core), full corpus 12/12 × both legs, `verify-live-zc.sh` PASS; evidence `artifacts/claim-899/` |

A machine-readable prefix (`FLAKE id=... gate=... status=...`) may be added
here alongside the table if a preflight ever needs to parse it; today the
table is the record (docs only, no tooling depends on it).
