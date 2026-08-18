# Claim: Milestone 13 Card B4 — desktop composition

- **Owner:** buffy (`agent/buffy/m13-b4-desktop-composition`)
- **Prompt / plan:** `docs/march-m13.md`
- **Scope:** Milestone 13, Card B4 (Issue #162: manifest-driven desktop composition)
- **Depends on:** B1/B2/B3 (merged, PRs #165/#167/#170); M11 `sys_exec` seam (claim 6359)
- **Status:** ✅ done 2026-08-16 — desktop composition live: DESKTOP.BIN walks the 9-entry manifest and launches FILE.BIN through sys_exec (slot 28); tools/verify-live-file-browser.sh PASS 1/1 on VZ

## Notes

The desktop has the pieces — a manifest-driven launcher (B2) and a
graphical file browser (B3) — but they have never been composed: the
capstone gate still exec'd `FILE.BIN` from the monitor, not from the
desktop. This card wires them together and proves the full arc live.

- `DESKTOP.BIN`'s hardcoded fallback catalog grows a ninth entry so
  `FILE.BIN` is present even when the manifest is missing (honest
  degradation, claim 8877), and `manifest_max_apps` 8 → 16 so the real
  nine-entry `APPS.TXT` parses without truncation.
- `tools/verify-live-desktop.sh` pins `desktop: manifest apps=9` (was 8).
- `tools/verify-live-file-browser.sh` is reworked from the B3 capstone into
  the B4 composition gate: it boots `DESKTOP.BIN` only, walks the manifest
  menu to FILE.BIN, and the first Return launches it through the M11
  `sys_exec` seam (slot 28) — the monitor never exec's it. The second Return
  then opens README.TXT. The syscalls report proves the seam: `sys_exec`
  once, `sys_dir_list` once, and `file_open`/`file_read` twice each (the
  desktop's manifest read plus FILE.BIN's README.TXT read).

- Class-A: `user/src/desktop.zig` 14/14 (new catalog-cap test); both live
  gates PASS on VZ.
