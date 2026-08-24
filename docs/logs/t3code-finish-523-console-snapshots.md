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
