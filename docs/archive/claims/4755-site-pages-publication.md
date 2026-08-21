# Claim: public documentation site + Boris GitHub Pages publication

- **Owner:** buffy (`freebuff/can-you-check-out-our-status-and-work-on-the-next--7e2ecd0b-8acc-47ac-bb44-68841236e5fc`)
- **Prompt / plan:** user-directed mission (no prompt file) — build and ship a
  first-class GitHub Pages documentation site for DipshitOS using Boris as the
  publication compiler, with Oliver's Pages implementation as the consumer
  reference.
- **Scope:** a new public content corpus (`site/`), a dedicated Boris theme
  (`themes/dipshitos/`), one pinned Boris toolchain revision
  (`.github/boris-pin.json`), a docs/site validation gate
  (`.github/workflows/docs-gate.yml`), a GitHub Pages publish workflow
  (`.github/workflows/github-pages.yml`), and a rewritten concise README.
- **Depends on:** —
- **Status:** ✅ done (verified 2026-08-14)

## Notes

DipshitOS had an engineering `docs/` warehouse but no public front door. This
claim adds the public site, keeping the warehouse as source material rather
than auto-publishing it.

**Boundary:** the public corpus is `site/` (ordinary Boris-authored Markdown —
8 trunks + 17 satellites, wiki-linked into a validated graph). The existing
`docs/` tree is unchanged as the canonical engineering warehouse; the site
promotes and summarizes it and links to canonical files on GitHub rather than
duplicating them.

**Theme:** `themes/dipshitos/` (layout + `assets/css/dipshitos.css` +
`footer.html`). Dark-first "modern OS documentation × old technical manual":
phosphor-green accent, Driving Award amber for warnings, system fonts only,
no JavaScript, responsive, visible-focus/keyboard accessible. Callouts
(VERIFIED / LIVE-GATED / PLANNED / LIMITATION / CLAIM-EVIDENCE) map onto the
closed Boris `Aside` component; status/evidence are text labels, never
color-only.

**Publication model (Boris v0.8.1 GitHub Pages flow):** one pin
(`.github/boris-pin.json` = revision `30805ab…`, the same revision Oliver
pins, on the Boris line that carries the Pages workflow) shared by the docs
gate and the publish workflow. The workflow resolves the Pages location via
`actions/configure-pages`, normalizes a publication profile, `boris plan`,
compiles `site/` with the project-site flags (`/DipshitOS`), prepares only the
verified inventory with `prepare-github-pages-artifact.sh` (so `_boris/proof`
stays out of the public artifact), retains proof/evidence separately, and
deploys with pinned Pages actions. An optional post-deploy HTTP audit carries
over from the reference workflow.

**Screenshot:** a fresh live capture (2560×1440, the ScreenCaptureKit
composited-window evidence path) showing Road Pops + the Driving Award clock
overlay is committed as the content-local asset `site/index.assets/screenshot.png`.

**Verification (observed):** pinned Boris built ReleaseSafe; `boris plan
--profile` reports `site_kind=project-site`, `base_path=/DipshitOS`; `boris
validate` passes (1 target); `boris` compiles 25 pages + sitemap + theme
assets; `prepare-github-pages-artifact.sh` verifies 28 files with
`proof_paths_excluded: true` and no `_boris/proof` in the public tree;
`site/index.assets/screenshot.png` is copied and referenced byte-exact.
Class A (`just verify-portable`) remains green — the kernel/tests are
untouched.

## Verified

- ✅ `boris validate --input site … --pages-base-path /DipshitOS` → `ok: validation passed for 1 target(s)`
- ✅ `boris … compile` → 25 pages + `sitemap.xml` + `assets/css/dipshitos.css` + `index.assets/screenshot.png`
- ✅ `prepare-github-pages-artifact.sh` → 28 files verified, `proof_paths_excluded: true`, no `_boris/proof` leak
- ✅ starter profile plans to `project-site` / `/DipshitOS`
