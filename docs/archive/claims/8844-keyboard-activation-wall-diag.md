# Claim: keyboard seam activation-wall diagnostic — the runner reports the key-window state (issue #179 follow-up)

- **Owner:** buffy (`freebuff/hey-bestie-the-chat-got-lost-so-we-re-so-back-can--53baf792-c2f8-470d-a9f1-6344aa90847a`)
- **Prompt / plan:** issue #179 — "synthesized keyboard seam now reports events=0 (verify-live-input.sh)"
- **Scope:** M7 I3 keyboard seam host-side diagnostics (not a guest change)
- **Depends on:** claim 4769 (the activation wall root cause, pinned in `docs/hardware-contract.md`)
- **Status:** ✅ done (2026-08-18)

## What is true (empirically re-confirmed)

Five `verify-live-input.sh` runs on the current console session
(established 2026-08-18 ~20:13 UTC) with the SAME binary and image:
PASS ×3 (16:30/16:35/16:38 EDT, `events=6 dropped=0`) and FAIL ×2
(16:20/16:33, `armed=1` but `events=0` with `KEY-SEQ … ok=true`) — the
pass/fail flip with zero code change. The guest USB stack is healthy
(`xhci: armed …`, `input: armed`) in both outcomes. Root cause: the
claim-4769 activation wall — synthesized-input translation is
session/machine-state dependent (macOS 14+ refuses programmatic
focus-stealing while another app holds focus). Not a code bug.

## The problem this claim fixes

The runner's synthesized-keyboard paths (`--input-key` KEY-INJECT,
`--input-string` KEY-SEQ, `--input-chords` CHORD-SEQ) report `ok=true`
when the NSEvents are dispatched to the view — which says NOTHING about
guest delivery. When the activation wall holds, the drop is silent and a
gate fails with `events=0` and no host-side clue.

## The change

Add a `reportKeyboardKeyState` helper and call it from all three keyboard
inject paths (`--input-key` KEY-INJECT, `--input-string` KEY-SEQ,
`--input-chords` CHORD-SEQ): it prints the window's `key`/`main`/`active`
state when the sequence starts, naming the activation wall (claim 4769)
and the recovery step when the window is not key. Pure diagnostics — no
event-dispatch behavior change. The message is deliberately non-
predictive: observed that `key=false` at the FIRST keystroke accompanies
BOTH an `events=0` fail and a full `events=6` pass (the wall can lift
mid-sequence), so the report is evidence, not a prediction.

## Evidence

- `bash tools/verify-live-input.sh`: PASS 3/5 on 2026-08-18 with the
  stock binary (the seam works); the FAIL runs now carry the host diag
  `KEY-SEQ: window key=false main=false active=false …` —
  `artifacts/live-input-run.txt`, `artifacts/kb-diag-run.txt`.
- Class A: `swift build --package-path host/vm-runner` green.
- Issue #179 closed as completed (root cause pinned as the environmental
  activation wall; no code fix exists — VZ has no programmatic keyboard
  API; re-run when idle / after a fresh login).
