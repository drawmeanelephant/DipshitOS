# Claim: GitHub Pages site refresh — reflect the shipped milestones and current state

- **Owner:** buffy (`docs/site-current-state`)
- **Prompt / plan:** inline — the public site had stopped at milestone seven while the repo had shipped through milestone twelve plus two of milestone thirteen's four cards
- **Scope:** docs only — the published `site/` tree (13 pages). NO kernel/user/host code changes, NO edit to `docs/status.md`, NO edit to the `docs/` planning tree.
- **Depends on:** the milestones it reflects, all already merged on `main` (M8–M12 plus M13 B2/B3)
- **Status:** ✅ done 2026-08-16 — the site now reflects reality: milestones 0–12 done, M13 in progress (B2 `APPS.TXT` manifest + B3 `FILE.BIN` browser live, B1/B4 open), the 34-slot syscall ABI, DNS, the desktop apps, and the honest bounds (no TCP server, no routing beyond NAT, the M8 U4 pointer-focus live seam)

## Notes

The GitHub Pages site (`site/`, published by the Boris workflow in
`.github/workflows/github-pages.yml` on push to `main`) had drifted far
behind the tracker: `index.md` stopped at milestone seven, `roadmap.md` said
milestone eight was active, `networking.md` claimed "no DNS resolver", and
`userspace.md` listed 21 syscalls while 34 were implemented.

Facts were verified against `docs/status.md`, the march trackers, the claim
files, and the code itself — one overreach was caught and corrected before
shipping (FETCH.BIN does not resolve hostnames via DNS; the resolver is a
kernel/monitor capability, so the site says that instead).

The exact docs-gate sequence was run locally with the pinned Boris revision
(`30805ab` from `.github/boris-pin.json`): `boris validate` passed, the
starter profile still plans to `/DipshitOS` as a project site, and a full
compile of all pages succeeded with the new content in the rendered HTML.

Pages touched: `index`, `roadmap`, `capabilities`, `networking`, `programs`,
`userspace`, `architecture`, `live-gates`, `graphics`, `input`, `storage`,
`kernel`, `run`. No `docs/` planning-tree file was modified.
