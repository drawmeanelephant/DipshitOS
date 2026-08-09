# Claim: Docs-current-state reconciliation (README / architecture / testing / roadmap / march / status vs. HEAD)

- **Owner:** buffy (`freebuff/okay-we-ve-been-kind-of-freestyling-off-away-from--0584ad0f-9850-473f-8884-7c28b20acab7`)
- **Prompt / plan:** user request 2026-08-08 — "make sure our documentation status changelog etc is all current and representative of where we actually are" (docs-only reconciliation of the stable-context documents against the actual state at `main` HEAD `181c2fc`).
- **Scope:** docs only — README, architecture, testing, roadmap, march-m15, status.md. No kernel/host/build/verification/hardware code changes.
- **Depends on:** main HEAD `181c2fc` (claims 0023 module split, 0015 NVRAM console, 6460 T0SZ diagnostic, 0176/4922 ragshit review, all landed); prior reconciliation claims 8592/8623/3109/0594/7256.
- **Status:** ✅ done 2026-08-08 — README/architecture/testing/roadmap/march-m15/status reconciled against HEAD `181c2fc` (claim-0023 kernel module split + ADR range 0001–0006 + `zig build nvram-console` in README; NVRAM-console + host-console gate rows and verify-nvram-console in README observed-behavior; testing.md gained the claim-0015 NVRAM-console step and class-D `t0sz16`; ladder wording reaches `M2_READY`; claim 6460 cited in README/architecture/roadmap/march step 8; status.md gate table refreshed to the 2026-08-08 preflight re-run and its stale fmt command corrected to `kernel/src/*.zig`); coordination gate, link check, stale grep, fmt, unit tests, and transcript gate all pass

## Notes

Prior reconciliation claims (8592 preflight, 8623 status/march reconcile, 3109 stale-doc cleanup, 0594 gate-inventory, 7256 post-MMU wording) left the canonical blocker current, but the following real drift remained at HEAD:

- `README.md` repository-layout kernel tree predates the claim-0023 `main.zig` split (missing `mmio`/`mmu`/`pci`/`evidence`/`virtio_console`/`nvram_console`/`machine` modules; `linker.ld` listed inside `src/` but it lives at `kernel/linker.ld`), and the ADR range says 0001–0004 (now 0001–0006).
- `README.md` verification-results table and "Observed behavior" omit the passing class-B NVRAM-console gate (claim 0015) and host-console gate; quickstart lacks `zig build nvram-console`.
- `README.md` / `architecture.md` / `roadmap.md` / `march-m15.md` do not cite claim 6460 (T0SZ 25→16 start-level diagnostic, 6/18 boots, not reproducible) — only `status.md`'s canonical blocker and `gate-inventory.md` do.
- `testing.md` class-D list omits `t0sz16` (claim 6460), the numbered sequence has no NVRAM-console gate step, and the marker-step ladder text stops at `M2_SERIA` (ladder now reaches `M2_READY`).
- `architecture.md` data-flow still says the NVRAM evidence channel "reaches M2_MMUP! → M2_SERIA" and omits the claim-0015 post-exit console channel.
- `status.md` gate-table "Last evidence" cells say "re-run 2026-08-06" although the class-A+B set was re-run again at HEAD `5160eef` on 2026-08-08 (claim 8592 preflight, `artifacts/status-preflight-*.txt`).

Verification: `bash tools/verify-coordination.sh` (index drift + claim ID), link check (no broken anchors/files), stale-phrase grep, `zig fmt --check` + portable unit/transcript gates unaffected (docs-only edits).
