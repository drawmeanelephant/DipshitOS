# Claim: fix stale verify-live-desktop / verify-live-file-browser manifest-count needles

- **Owner:** buffy (`agent/buffy/fix-desktop-manifest-count`)
- **Prompt / plan:** user-reported pre-existing red gates (triaged during
  HF4, issue #738 work): both `tools/verify-live-desktop.sh` and
  `tools/verify-live-file-browser.sh` assert `desktop: manifest apps=12`
  while `image/apps.txt` has carried **19 entries** since the M32 ZC.BIN
  commit — the M30/M31 ELF rows (DYNAPP.ELF, CALC.ELF, NOTEPAD.ELF,
  FILE.ELF, DESKTOP.ELF) and M32's ZC.BIN all landed after the last
  count bump (M27 G6's SYSMON.BIN row, `apps=12`). The gates are NOT in
  CI (class-B), so the staleness rotted silently. Live fallback proof from
  HF4: on a no-share boot the desktop prints `desktop: manifest apps=19`
  (parse_manifest skips `#` comments and blank lines).
- **Scope:** gate needle updates only — `apps=12` → `apps=19` (grep +
  error text + rationale comments) in `tools/verify-live-desktop.sh` and
  `tools/verify-live-file-browser.sh`, plus the stale "11 entries" /
  "9 apps incl FILE.BIN" comment strings in the file-browser header and
  report. No kernel/user code changes; FILE.BIN stays manifest index 8
  (all appends landed below it), so the 8-down-arrow chord is unchanged.
- **Touches:** `tools/verify-live-desktop.sh`, `tools/verify-live-file-browser.sh`,
  `docs/claims/1732-fix-desktop-manifest-count.md`,
  `docs/logs/agent-buffy-fix-desktop-manifest-count.md`
- **Depends on:** — (red gates are pre-existing staleness; no milestone card)
- **Heartbeat:** 2026-09-01
- **Status:** ✅ done — both gates PASS 1/1 on VZ (`desktop: manifest apps=19`
  accepted); bonus staleness found in the same gate family: the
  file-browser gate's `sys_dir_list calls=1` / `sys_file_open calls=3`
  needles were also stale (now calls=2 / calls=6, see the claim log).
  Class-A green (fmt, build, 24/24 unit tests, 824 console tests).
