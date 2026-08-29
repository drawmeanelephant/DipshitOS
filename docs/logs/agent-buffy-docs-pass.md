# Log — agent/buffy/docs-pass

## 2026-08-28 — claim 3377 (docs pass: README, AGENTS, status, GitHub Pages → M31)

The local checkout sat on `agent/buffy/input-poll-563`, which PR #593 had
already merged; `origin/main` had moved to M28 (SMP), M29 (VM depth),
M30/M31 (dynamic linking), the `HTTPD.BIN` in-guest web server, the M26
offline-preflight cards N13/N14, and the `sys_tcp_connect` wall-clock fix.
Every GitHub milestone is closed and the issue tracker is at zero open
issues — but README.md, AGENTS.md, and the GitHub Pages corpus still claimed
we were on milestone 13/14/16. This claim is the overall documentation pass:
fresh branch off `origin/main`, facts cross-checked against the GitHub API,
kernel sources, build manifest, and march trackers.

- README.md Status rewritten: M0–M31 summary, the hardware-depth trio
  (M28/M29/M30/M31), post-milestone landings, zero-open-issues state, no M32
  defined yet; Layout's `user/` entry now names `.ELF`/`.SO`.
- AGENTS.md Current milestone: 0–31 closed, both former open threads
  resolved (#151 class-B-headless pointer injection, #179 virtio input
  channel), no M32.
- docs/status.md: M17–M31 added to the Current position table with
  GH-milestone/issue/claim citations and exact card ranges (M19 P1–P16,
  M22 D1–D16, M23 E1–E25, M24 K1–K16, M25 F1–F18, M26 N1–N16, M27 G1–G30);
  "What comes next" rewritten (everything closed, ABI effectively full at
  65/128 implemented, ADR 0013 reserved 52–54); stale open-thread line
  removed; march-tracker note widened to M18–M31.
- site/ (GitHub Pages): index (status table through M31, what-runs-today
  with SMP + dynamic linking + HTTPD, 65-of-128 ABI), roadmap (shipped
  table through M31, "no active milestone" current section, honest bounds
  updated), architecture (diagram + subsystem table: 2-core SMP, 11-slot
  scheduler, 65/128 syscalls, LD.SO layer), capabilities, networking
  (TCP client + passive-open server, HTTPD), memory (M29 demand paging/COW/
  mmap, 11-slot pool), processes (11/11 pool, eight concurrent), userspace
  (ABI table extended to slots 46–64), programs (47 flat images + dynamic
  .ELF/.SO inventory, verified against `build.zig`), run (69 monitor
  commands), live-gates (136 gate scripts, M21–M31 + custom-virtio groups),
  build (dynamic ELF pipeline note), drivers (custom-virtio row, balloon
  note corrected).
- No kernel/userland/host behavior changes — docs only. ✅ done.

## 2026-08-28 — M32 WM-server migration planning (docs only; claim 2852)

- ADR 0015 (proposed): route desktop *policy* out of the kernel compositor into
  a userland WM server; kernel becomes a thin render + input + surface server
  (seam A). Reserves slot 65 `sys_wmctl` (register/set-window/request-present,
  WM-exclusive) + event kind 18 `COMPOSITE_TICK` (WM drives pacing, off the
  shell idle). Shim-and-slim so M18–M31 gates never regress; seam B (full pixel
  ownership via cross-process shared mmap) explicitly deferred.
- docs/march-m32-wm-migration.md: WMS1–WMS10 card plan (ADR/slot, render-server
  register, WM server scaffold, chrome→geometry→desktop-chrome drain-out,
  app↔WM IPC, kernel slimming, surface-seam perf, deferred seam B).
- docs/status.md: "What comes next" M32-scope pointer line (claim 2852).
- No kernel/userland/host behavior changes — planning docs only.

## 2026-08-28 — M32 GitHub milestone created (issues #621-#630)

- Created GitHub milestone 16 "M32 — Window manager server migration"
  (https://github.com/drawmeanelephant/DipshitOS/milestone/16).
- Filed 10 open issues against it, one per WMS card: #621 WMS1 (ADR 0015 +
  slot 65), #622 WMS2 (render-server register), #623 WMS3 (WM server scaffold),
  #624 WMS4 (chrome out), #625 WMS5 (geometry out), #626 WMS6 (desktop chrome
  out), #627 WMS7 (app↔WM IPC), #628 WMS8 (slim kernel), #629 WMS9 (surface-seam
  perf), #630 WMS10 (deferred seam B). All bodies cite ADR 0015 /
  docs/march-m32-wm-migration.md.
- docs/status.md milestone-16 pointer + issue range (claim 2852).
- Docs-only coordination change; no code.

## 2026-08-28 — M32 issue bodies scoped (#621–#630, milestone 16)

- Rewrote all ten issue bodies from one-line sketches into scoped cards, one
  fixed template each: Goal / Why this order (depends + blocks) / In scope
  (checkboxes) / Out of scope / Acceptance (gate) / Risks / Touches. Drafted
  under `artifacts/m32-issue-bodies/621..630.md` (evidence), then pushed with
  `gh issue edit` (authenticated as the repo owner).
- Scoping additions beyond the original draft (marked per-issue as "new — not
  in the draft"):
  - #622 (WMS2): WM-death teardown — kernel unregisters a dead WM and pacing
    falls back to the shim; present-sequence counter as the parity cards'
    observability primitive; new gate `verify-live-wmctl-register.sh`.
  - #623 (WMS3): bootstrap decision (who execs WND.BIN; default VM stays
    shim-only so all gates are non-interference green); hung-WM watchdog;
    single-source pure-logic extraction mechanism decision.
  - #625 (WMS5): input-seam handover scoped — the WM hit-tests and decides
    focus/drag; the kernel only fans the raw stream out (today the kernel
    does it: `driving_award.zig:2328`, `input.zig:384`); pointer-pacing
    latency must be measured against the ~2.5 s shell-idle cadence.
  - #627 (WMS7): mailbox-size decision grounded in the real bound (mailbox is
    8 slots × 64 B, `mailbox.zig`); prefer growing the constant over a new
    syscall; sync-shaped toolkit API over async transport decided explicitly.
  - #629 (WMS9): prior-art correction — slot 46 `sys_win_fill_batch` already
    exists (issue #205); measure it first, extend its payload instead of
    adding a slot; pixel-identical output is the bar.
  - #630 (WMS10): deferred card turned into a scoping seed (shared-anon mmap
    requirements, damage tracking, capability/security ADR) so the post-M32
    end-state is written down but fenced off.
- docs/march-m32-wm-migration.md: table gains Phase/Depends columns + issue
  links; new "Dependency phases" diagram (WMS1 contract → WMS2/WMS3 unlock →
  WMS4–WMS6 drain-out → WMS7 protocol → WMS8/WMS9 payoff → WMS10 deferred)
  with the hard edges called out; WMS9 row corrected for slot 46; Notes 2–6
  updated (zero-regression per drained feature, ABI budget at 66, robustness
  properties, verification-first ordering).
- docs/status.md M32 paragraph: pointer to the scoped bodies + order.
- docs/claims/2852-wm-server-migration.md: scoping addendum section.
- Docs-only change (issues + planning docs); no kernel/userland behavior
  change. Claim 2852 stays 🔄 until the milestone-scoping branch merges.

## 2026-08-28 — WMS1 proposal drafted, posted, folded into claim 2852

- Drafted `docs/m32-wms1-acceptance-proposal.md`: the ready-to-apply WMS1
  (#621) acceptance checklist with verbatim ADR 0007 slot-65 amendment
  (three-subcommand encoding table: REGISTER/SET_WINDOW/REQUEST_PRESENT with
  arg + per-command error layout), the ADR 0009 kind-18 row + routing-
  restriction note, the events.zig constant, and the ADR 0015 status-flip
  block. Committed (1dea17d) and pushed on this branch (PR #631).
- Posted the full proposal as a comment on issue #621
  (comment-5459368923) so the implementing agent finds it in the tracker.
- Folded the proposal into claim 2852's scoping addendum as the canonical
  copy (subheaders demoted to nest under the addendum; the standalone
  `docs/m32-wms1-acceptance-proposal.md` was removed to keep one canonical
  source on the PR).
- Frozen-enum fix resolved: ADR 0015's draft `EPERM` for non-WM callers
  **does not exist** in the kernel `ErrorCode` enum (syscall.zig:285, top
  at -10 ENOMEM); the proposal assigns `EACCES` (-7) for the WM-exclusive
  refusal, plus seat-taken → EACCES (with an EL1h force-unregister escape),
  no-GPU REGISTER → ENXIO (-9), and COMPOSITE_TICK on the scheduler tick
  seam. Slot-count tail corrected: `slot_count` is 128, so the amendment
  writes the honest "reserved 66–127" bound.
- Docs/planning only; no kernel/userland behavior change.
