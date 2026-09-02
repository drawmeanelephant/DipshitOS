# Claim: Fix stale desktop-manifest needle (apps=19 → 21), close #729

- **Owner:** t3code (`agent/t3code/729-desktop-manifest-21`)
- **Prompt / plan:** Issue #729 — `verify-live-desktop` red on main.
- **Scope:** Gate-needle bump only. No guest/kernel/host code changes.
- **Touches:** tools/verify-live-desktop.sh, tools/verify-live-file-browser.sh, docs/claims/6854-*, docs/logs/t3code-20260902-1.md
- **Depends on:** —
- **Heartbeat:** 2026-09-02 — done
- **Status:** ✅ done 2026-09-02 — `verify-live-desktop` PASS on VZ at HEAD+patch; `verify-coordination` ok

## Findings

- Issue #729's symptom (`desktop: launch CALC.BIN err=6`, ENOENT via EL0
  `sys_exec` while shell exec worked) does **not** reproduce on current
  main. Its suspected stack (`esp.zig`/`fat.zig`, DSK3 + PR #724
  load-on-demand) is gone — M34 HF6 deleted the FAT/ESP stack (PR #806)
  and exec now goes over the host file channel.
- Observed on HEAD `98a5478` (2026-09-02, VZ, macOS 27.0):
  `desktop: manifest apps=21`, `desktop: launch CALC.BIN pid=4`,
  `calc: ready` — the EL0 exec seam works; CALC launches from the desktop.
- The gate's remaining red is a stale hardcoded needle `apps=19` (set
  2026-09-01, claim 5251). `image/apps.txt` grew to 21 entries when the
  M19 sexiburger rows (`SEXIBURG.BIN`, `SEXITEST.BIN`) landed (5845d7f).
- Same stale needle exists in `tools/verify-live-file-browser.sh`
  (identical manifest-marker assertion); fixed in the same commit.
- No ACTIVE claim declares either file (2259 ✅ done, 8777 ✅ resolved);
  9094/1432 touch `virtio_file`/`exceptions`/`scheduler`/`monitor`, none
  of which this claim edits.
