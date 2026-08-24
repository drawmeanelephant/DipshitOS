# Log — t3code/finish-523-console-snapshots

## 2026-08-24 — claim 0680 filed: structured console + FB snapshots (#523 item 3 capstone) + merge queue (#523 item 6)

Re-assessed issue #523 against `main` `123baca`: items 1/2/4/5 landed,
item 3 has input injection done (claims 9588/9367) with structured console
and framebuffer snapshots still open, item 6 (merge queue) untouched.

This branch takes the remaining tranches: kind-3 console-tee arm message
+ line tee onto queue 1 (`--cvc-console-file`), kind-4 snapshot request +
raw-chunked frame streaming over queue 1 (`--snapshot-after`), headless
end-to-end gate `verify-live-virtio-e2e.sh` (injected input in, structured
console + snapshot out — the #523 acceptance row verbatim), then GitHub
merge-queue enablement via API with the config recorded in
docs/branch-protection.md. Claim: `docs/claims/0680-virtio-console-snapshots.md`.

## 2026-08-24 — claim 0680 done: e2e gate PASS; #523 item 3 complete, item 6 documented-blocked

Landed: kind-3 console-tee arm + queue-1 tee (`--cvc-console-file`),
kind-4 snapshot request + FIFTH-queue raw-chunked framebuffer streaming
(`--cvc-snap`, `--snapshot-after`), and `verify-live-virtio-e2e.sh` —
PASS headless on macOS 27.0 build 26A5416b (injected input in, structured
console + checksummed snapshot out, no synthesis/SCK in the critical path).
Regressions green unchanged: GATE_VIRTIO=1 verify-live-input,
pointer-virtio, cvc-echo, custom-virtio.

Two live findings worth remembering (pinned in hardware-contract.md):
(1) submit+wait without free_chain_q leaks two descriptors per send — the
spike's five lines hid it, sustained tee traffic exhausted the 32-ring in
seconds (every later send dropped by counter); fixed with defer-frees.
(2) RFC-1071 overflows u32 at whole-frame scale (~1.2e11 max sum) — the
host crashed mid-stream with a Swift arithmetic-overflow trap; both sides
now accumulate u64. Also: injected keys go to whichever window owns focus,
so a gate must type before opening user windows.

Item 6 (merge queue): REST rulesets PUT rejects `merge_queue` for this
repo even on a disabled probe ruleset — plan-gated (Team/Enterprise). No
partial state; exact config + ready-to-run call recorded in
docs/branch-protection.md. Claim flipped ✅.
