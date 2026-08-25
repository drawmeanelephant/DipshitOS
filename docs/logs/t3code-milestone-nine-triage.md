# Branch log — `t3code/milestone-nine-triage`

Append-only. One entry per unit of work; never rewrite or delete.

---

## 2026-08-24 — claim 8777 opened: M21 window-management gate sweep (W1–W16)

- **Claim:** `docs/claims/8777-m21-window-gate-sweep.md` (🔄)
- **Context:** GitHub milestone 9 ("M21 — Window management depth") triage.
  Survey at HEAD `9bc0ec2`: W1–W5 merged via #488, W9/W11/W12 via 1a8dedf,
  W6–W10 primitives wired to live chords in shell.zig (maximize landed as
  Ctrl+Shift+M; the issue's Ctrl+M belongs to W2 master-swap). No M21 card
  has observed evidence: no gates exist, march-m21.md is empty of evidence
  and lacks W6–W16 rows, all issues open except W9.
- **Plan:** verification-first sweep in milestone order — per-card class-B
  gates (`tools/verify-live-m21-*.sh`, win-move/claim-0487 pattern with
  EL1h `dui` halves for chord entries), gap fixes as found (known gaps:
  W14 unimplemented; W15/W16 unwired), doc flips + issue close-outs with
  artifacts under `artifacts/`.
- **Next:** W1+W2 tiling/master-detail gate first.
