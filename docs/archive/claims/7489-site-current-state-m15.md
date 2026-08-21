# Claim: GitHub Pages site refresh — reflect M14/M15 shipped and the M16 stream

- **Owner:** opencode (`docs/site-current-state-m15`)
- **Prompt / plan:** inline — the public `site/` tree stopped at the milestone-thirteen status sweep (`e1187c6`) while M14 (shared user services) and M15 (audio) shipped complete on the same day
- **Scope:** docs only — the published `site/` tree (9 pages: index, roadmap, userspace, architecture, drivers, programs, capabilities, live-gates, kernel). NO kernel/user/host code changes, NO edit to `docs/status.md`, NO edit to the `docs/` planning tree.
- **Depends on:** the milestones it reflects, already merged on `main` (M14 claims 0169/7323/3289/4482; M15 claims 6140/5877/7636/3206; M16 planned, issues #190–#193)
- **Status:** ✅ done 2026-08-19 — the site now reflects reality: M14 + M15 shipped, M16 the current stream, 46-slot syscall ABI (slots 0–45), 27 ESP `.BIN` programs, virtio-snd (DID 0x1059), the 71-gate live set, and the 47-command monitor registry

## Notes

The GitHub Pages site (`site/`, published by the Boris workflow in
`.github/workflows/github-pages.yml` on push to `main`) had drifted behind
the tracker again: `index.md` and `roadmap.md` still presented milestone
fourteen as the active stream with S1–S4 planned, `userspace.md` listed 38
implemented syscalls while 46 were implemented, `programs.md` listed 22
`.BIN` images while 27 ship on the ESP, `drivers.md` had no virtio-snd row,
`live-gates.md` said 43 gates while the live set is 71, and `kernel.md`
said the monitor registry held 44 commands while it holds 47.

Facts were verified against `docs/status.md`, the march trackers, the claim
files, and the code itself (syscall `implemented_count` in
`kernel/src/syscall.zig`, `registry_count` in `kernel/src/monitor.zig`, the
`make-image.sh` program list, and `tools/verify-live-*.sh`).

The exact docs-gate sequence was run locally with the pinned Boris revision
(`30805ab` from `.github/boris-pin.json`): `boris validate` passed, the
starter profile still plans to `/DipshitOS` as a project site, and a full
compile of all pages succeeded with the new content in the rendered HTML.

Pages touched: `index`, `roadmap`, `userspace`, `architecture`, `drivers`,
`programs`, `capabilities`, `live-gates`, `kernel`. No `docs/` planning-tree
file was modified.