# Log — M34 HF4 app delivery from the host folder (issue #738)

Branch: `agent/buffy/m34-hf4-exec` · Worktree: `../virelaios-buffy`
Claim: [7599](../claims/7599-m34-hf4-app-delivery.md)

### 2026-09-01 — claim filed, design pinned
HF1–HF3 landed; HF4 takes the deletion payoff's first slice: exec from the
share. Design decisions pinned here for the review:

- **Host share is the PRIMARY exec source when the channel is present.**
  `exec.zig` tries the share first (STAT via queue 5, then chunked READ
  round trips into the existing 256 KiB `program` staging buffer), and
  falls back to the ESP FAT path only when the file is absent there — the
  issue's "instead of the ESP FAT path" with the "dual path until HF6"
  safety. Default boots have no `--cvc-file` → `virtio_file.available()`
  false → byte-identical. A host file bigger than the 256 KiB buffer is
  `.too_large` before any read.
- **The desktop manifest re-point rides the EXISTING file seam.** The
  kernel file table gains a read-only `.host` partition (`/host/...` →
  vf LIST/READ/STAT, no FAT mount), so `DESKTOP.BIN` reads
  `/host/APPS.TXT` through `ui.file_open` with zero new syscalls; on
  failure (no channel / absent) it falls back to `/esp/APPS.TXT`.
  Writes/truncate/delete/rename on `/host` return honest read-only errors
  — HF5 re-homes user data with the write path.
- **The gate proves "no image rebuild" honestly.** `verify-live-vf.sh`
  builds the tiny app ELF (freestanding aarch64, `user/linker.ld`, one
  PT_LOAD at `userspace.text_va` — verified parse-clean) AFTER the image
  is baked and drops it into the private per-run share; the boot then
  lists it (`vf ls`), execs it (marker + `tasks user-exec exited
  status=43`), and DESKTOP.BIN prints `desktop: manifest apps=2` from the
  HOST manifest (the ESP one has 19) — the re-point proof, headless
  (manifest marker prints before the no-framebuffer window failure).
- **No wire change, no new BSS.** `read_into` reuses `vf_reply_buf`;
  exec reuses `program`; file_table adds only an enum arm. BSS budget and
  all fixtures untouched.

### 2026-09-01 — live verification, regressions, and landing notes
- **verify-live-vf.sh now covers HF1–HF4 and PASSes 4/4 on real VZ** (one
  phase per boot: mutate / read-back / delete / app-delivery). The HF4
  phase compiles the app ELF on the host AFTER the image is baked, drops
  it + a 2-entry `APPS.TXT` into the share, and asserts: `vf ls` lists
  HF4APP.ELF; `exec HF4APP.ELF` streams it across 3 READ round trips
  (32765+32765+374 of 65904 bytes, host log) and runs it — `hf4: hello
  from host` + `tasks user-exec exited status=43`; `exec DESKTOP.BIN`
  prints `desktop: manifest apps=2` from the HOST manifest (the ESP one
  has 19) — the manifest re-point proof. Three live-debug finds pinned
  here: (1) the heredoc needs `\\` (escaped backslash) Zig-asm escapes —
  single backslashes made `zig build-exe` reject the file; (2) the
  app-phase boot needed a longer window than the 90 s default — the first
  runs cut the app's final marker mid-write at the deadline (phase timeout
  150 s); (3) the marker is 20 bytes, not 19 — `x2=#20`. The app-phase
  `exec: loaded` needle is a prefix line, so it greps substring (the other
  needles are whole lines).
- **Class A**: `verify-vf-class-a` PASS (BSS unchanged — 10,972,600 B,
  no new buffers; wire parity + coordination green). New file_table host
  parse test + virtio_file.read_into (49 tests), exec (516), desktop (51)
  all green; `zig fmt` clean.
- **Regressions**: `verify-live-asm` PASS (exec PROG.ELF — ESP ELF path
  untouched), `verify-live-virtio-e2e` PASS (custom-virtio control plane),
  and a targeted no-share boot of DESKTOP.BIN prints `desktop: manifest
  apps=19` — the `/esp` fallback is byte-identical. 
- **Pre-existing red, NOT this card**: `verify-live-args` FAILS 0/1 on
  CLEAN MAIN too (stash-tested) — with four concurrent argv-printing
  USER.BINs the idle-seam console partial flush splits writes, printing
  `user: arg=` and the arg on separate lines (the same symptom class as
  the M4-era claim-4636 payload bug, but from console flush timing, not a
  payload bug — USER.BIN's prefix length is #10 as fixed). Also
  `verify-live-desktop` asserts `desktop: manifest apps=12` while
  image/apps.txt has carried 19 entries since the M32 ZC.BIN commit — a
  stale manifest gate on main (not in CI), left for HF6-era cleanup.
