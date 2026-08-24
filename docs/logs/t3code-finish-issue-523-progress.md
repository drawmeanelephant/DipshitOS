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

## 2026-08-24 — claim 9367 done: pointer injection PASS, #151 upgraded to class-B-headless

Implemented kind-2 absolute-pointer messages over custom-virtio queue 3:
guest dispatch (`virtio_custom.zig` + `on_pointer_report` hook wired to the
renamed `input.decode_pointer_report`), host `--pointer-virtio`/
`--pointer-virtio-after` (same step grammar as `--pointer`, pixel→HID-
logical conversion, strict-order delivery ladder), wire format + two live
findings pinned in `docs/hardware-contract.md`.

Live verification: `verify-live-pointer-virtio.sh` PASS on a real VZ boot
(headless: no --display, no --input, armed=0 with ptr-reports=8; focus
moves `dui: pointer focus=2` → `focus=0`). Two debugging findings worth
remembering: pointer presses need per-idle-pass granularity (2.5 s pacing,
not 0.25 s — observed collapse at 0.25 s), and hit_test scans array order
so a user window must be raised above the fullscreen terminal before
clicks land. Regression `GATE_VIRTIO=1 verify-live-input.sh` PASS
unchanged; unit tests green (27/27 virtio_custom incl. new kind-2 test,
189/189 input). Claim 9367 flipped ✅.
