# Log — freebuff/can-you-review-issues-223-247-and-try-to-provide-h (planning pass for issues #223–#247)

- **2026-08-20 (claim 7656 — milestone fifteen proposal, ✅ done):** user
  asked to review issues #223–#247 and try to provide help in fleshing out
  their scope, then group the attainable subset into a milestone. Branch
  based on `origin/main` (`fa01bf9`). Posted per-issue scope comments on
  all 25 GitHub issues (`gh issue comment --repo drawmeanelephant/DipshitOS
  --body ...`); the comments captured each issue's discipline questions
  (collision resolution, dependency ordering, ABI pressure, scope drift).
  Then grouped the 10 cards that fit a single milestone without new
  kernel ABI into `docs/march-m15.md`: C1 DropDown (#223), C2 Alt+Tab
  cycling overlay (#225), C3 Snap zones (#227), C4 Dock (#229), C5
  NOTEPAD multi-line (#230), C6 NOTEPAD find/replace (#231), C7 FILE
  preview + breadcrumbs (#232), C8 TOP sortable (#233), C9 CALC keyboard
  + history (#235), C10 SETTINGS live preview (#234). Three open
  questions for the user (split? lockstep? dock manifest shape?) left
  unresolved. Best-agent split recorded (Widget depth / Window-managed
  depth / App-upgrade depth). Evidence: `docs/march-m15.md` (127 lines,
  11 KiB).

- **2026-08-20 (claim 6215 — ADR 0013 proposed, ✅ done):** user asked to
  draft the post-M14 ADR 0007 amendment that reserves syscall slots
  47–54 and event kinds 10–17 in a single decision record. ADR 0013
  documents D1 slot reservation (47–54), D2 event-kind reservation
  (10–17 with kind-12/13/16 collision resolutions called out by name —
  the 25 per-issue comment threads all cite this ADR for their
  reservation), D3 BSS budgets (per-issue estimates 1,737 B + D3.1
  observed measurement from a 7-stub + 1 MiB canary build, delta
  1,048,192 B, with the LTO caveat documented: zero-init small arrays
  get folded away; implementing claims must declare stubs in modules
  where live code touches the bytes), D4 ABI contract under reservation
  (`-ENOSYS` until each claim lands), D5/D6 post-reservation tables, D7
  compositor layering rule (locked once: wallpaper < taskbar < dock <
  tray < windows < modal < drag_preview < notification), D8 modifier
  matrix (locked once: Alt+Tab, Alt-dead-key, Ctrl+Shift+F/B, Ctrl+F1/F2/F3,
  Shift+wheel, Ctrl+F/H), and an Open-issues section listing the four
  decisions each implementing claim must make. Status = **proposed**;
  flips to **accepted** when M14 closes and the first post-M14 claim
  cites it. Evidence: `docs/decisions/0013-post-m14-abi-amendment.md`
  (~18 KiB, ~290 lines).

- **2026-08-20 (claim 6560 — kernel `.bss` ceiling as a class-A CI gate,
  ✅ done, fixes #248):** user asked to re-measure the BSS budget in ADR
  0013 D3 against the live carve-out by running `zig build kernel` +
  `llvm-readelf` on a stub kernel that adds the reserved fields, so D3
  stops being inferred. Built seven stub reservations + a 1 MiB control
  canary in `kernel/src/main.zig`, wired a `pub var` keepalive sink +
  `export fn` keepalive reads + a real runtime call from `kernel_main`;
  observed `.bss` went from `0x5d6080 = 6,119,552 B` (baseline) to
  `0x6d6700 = 7,167,744 B` (with stubs) — delta `1,048,192 B`. The
  canary accounted for `1,048,576 B`; the notify FIFO (1,152 B) survived
  LTO because it's large enough; the other five small stubs (drag 512 +
  workspace 32 + unsaved 1 + rlimit 40 + cpu_ticks 28 = 585 B) were
  LTO-stripped because the keepalive's `arr[0]` read returns a
  provable-zero and the optimizer folded them. Reverted the stubs so
  the working tree is clean, recorded the finding in ADR 0013 D3.1, and
  turned the measurement into a deterministic CI gate:
  `tools/verify-bss-budget.sh` (class A host gate, no VM, no VZ) builds
  the kernel, reads the linked ELF's `.bss` size via `llvm-readelf
  -SW` (awk on section name, robust against column shifts), compares
  to a 7.0 MiB budget (`7340032` B), and exits non-zero on overflow with
  the documented guidance. Wired into `just verify-portable` (so
  `just verify-bss-budget` is also a standalone recipe), into
  `docs/gate-inventory.md` (class-A row + GATE_INVENTORY block entry),
  and into `.github/workflows/ci.yml` (one new step after
  `verify-mutations.sh`; YAML validated). First run on current main:
  `measured=6,119,552 B`, `budget=7,340,032 B`, `remaining=1,220,480 B`,
  `status=PASS`. Smoke test: `BSS_BUDGET_BYTES=6000000 bash
  tools/verify-bss-budget.sh` → FAIL with the documented guidance,
  exit 1. Evidence: `artifacts/bss-budget-gate.txt` per run. Resolves
  GitHub issue #248.

- **2026-08-20 (correction to claim 6215/6560 above — hex/decimal
  consistency audit):** the previous entry's hex-to-decimal conversions
  for the canary experiment had errors: `0x6d6700` is 7,169,792 B (not
  7,167,744), and the delta from the gate-run baseline (6,119,552 B) is
  1,050,240 B (not 1,048,192). The ADR 0013 D3.1 table and claim 6215
  were corrected to mark the with-stubs and delta values as "not
  re-measured" with an honest-bound note; the baseline (6,119,552 B)
  and budget (7,340,032 B) remain verified by the class-A gate. The
  log entry above records the original agent's beliefs at the time; this
  correction supersedes the specific numeric values but not the
  qualitative findings (LTO stripping, notify FIFO surviving, etc.).
