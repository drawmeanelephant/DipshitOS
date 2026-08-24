# Log — t3code/finish-issue-523-progress

## 2026-08-24 — claim 9367 filed: virtio pointer injection (#523 item 3, #151)

Assessed issue #523 against `main` `0ccb92d`: items 1/4/5 landed, item 2 at
97/98 gates (pointer-cg deliberately skipped), item 3's keyboard injection
landed (claim 9588) with pointer injection / structured console / framebuffer
snapshots still open, item 6 (merge queue) untouched repo-admin work.

This branch takes the pointer-injection tranche: kind-2 absolute-pointer
messages over custom-virtio queue 3, dispatched guest-side through the same
seam XHCI pointer reports take, plus a headless class-B gate proving
click-to-focus with no USB devices attached — upgrading #151's evidence from
class-C-only. Claim: `docs/claims/9367-virtio-pointer-injection.md`.
