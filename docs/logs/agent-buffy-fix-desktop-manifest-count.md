# Log — fix stale desktop manifest-count gate needles

## 2026-09-01 — claim 1732: stale manifest-count needles in the two desktop gates

- **Problem:** `verify-live-desktop.sh` and `verify-live-file-browser.sh`
  assert `desktop: manifest apps=12` (last bumped by M27 G6's SYSMON.BIN
  row), but `image/apps.txt` has 19 entries: the M30/M31 dynamic-app ELF
  rows and M32's ZC.BIN landed after the last bump. Class-B gates aren't
  in CI, so the staleness rotted on main.
- **Count verified:** `image/apps.txt` has 19 non-comment, non-blank
  `NAME.BIN | Display | icon` rows (CALC.BIN … ZC.BIN); the `#` header is
  skipped by `parse_manifest` (`user/src/desktop.zig`). HF4 observed the
  live marker `apps=19` on a no-share boot — the two gates' expectation
  was the only stale side.
- **Fix:** needle + error text + rationale comments `apps=12` → `apps=19`
  in both gates; refreshed the file-browser header ("11 entries today" →
  19) and its report line ("9 apps incl FILE.BIN" → 19). FILE.BIN remains
  manifest index 8 (every append since M13 landed below it), so the
  8-down-arrow chord sequence is untouched.
- **Verification:** both gates PASS 1/1 on VZ (see artifacts/
  live-desktop-*.txt / live-file-browser-*.txt); class-A checks green.

## 2026-09-01 — claim 1732 landed: file-browser syscall needles too

- Running the file-browser gate after the apps=19 needle exposed a SECOND
  staleness in the same file: the syscalls-report assertions pinned
  `27 sys_dir_list calls=1` and `23 sys_file_open calls=3`, but live
  observation showed calls=2 / calls=6. Counted from source:
  - `sys_dir_list` 2 = main listing + F4's bounded du walk (claim 2539,
    one extra dir_list per level; /data has no depth-1 subdirs).
  - `sys_file_open` 6 = desktop /host/APPS.TXT open (HF4 host-first,
    fails without a share but the CALL counts) + /esp/APPS.TXT manifest +
    FILE.BIN recent-ring load (absent, still counts) + C7 preview
    (DATA.TXT) + view (DATA.TXT) + recent-ring save (claim 2539).
  - `sys_file_read` stays calls=3 (the failing/saving opens never read) —
    that needle already matched.
- Updated the gate's needles, error text, and rationale comments; header
  note refreshed. Desktop gate re-verified green (apps=19), file-browser
  gate PASS 1/1 on VZ. CI-equivalent fmt, `zig build`, 24/24 unit tests,
  824 console tests, transcript, and coordination all green.
- Pre-existing, NOT touched: `zig fmt --check user/src/calc/defs.zig`
  fails on the HEAD version too (subdirectory — CI's `user/src/*.zig`
  glob never sees it).
