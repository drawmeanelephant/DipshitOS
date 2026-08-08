# Claim: Docs-only reconciliation — make status.md / march-m15.md reflect already-landed evidence

- **Owner:** buffy (`freebuff/docs-reconciliation-m15-status-20260808`)
- **Prompt / plan:** task prompt 2026-08-08 — docs-only reconciliation from latest main `fff37a5`; scope restricted to canonical stable-context docs; do not modify kernel, host, build, verification, or hardware code; reconcile suspect areas 1–7 against current tracked evidence
- **Scope:** docs-only reconciliation of `docs/status.md`, `docs/march-m15.md`, `docs/roadmap.md`, `docs/architecture.md`, `docs/hardware-contract.md`, `docs/gate-inventory.md` (pointers/classification only), `docs/testing.md`, `README.md` — make them accurately reflect evidence ALREADY landed (claims 0002/0015/0017/0018/0020/0021/0022/8592 and ADRs 0004/0005/0006); delete stale duplicate status prose, label superseded narratives as historical, make blocker/next-work ordering canonical; no milestone-scope change, no invented results, no [inferred]→[observed] upgrades beyond what claims already record
- **Depends on:** main `fff37a5`, claims 0002/0010/0013/0015/0017/0018/0020/0021/0022, ADRs 0004/0005/0006, claim 3109 (prior stale-doc cleanup) and 8592 (preflight report, gitignored)
- **Status:** ✅ done 2026-08-08 — docs/status.md and docs/march-m15.md reconciled against claims 0013/0015/0017/0018/0020/0021/0022 and ADRs 0004/0005/0006; verification gates pass (see artifacts/docs-reconciliation-20260808/)

## Notes

Deterministic claim ID `8623` derived as `0024 + (cksum("freebuff/docs-reconciliation-m15-status-20260808:docs-reconciliation-m15-status") % 9976)` via `bash tools/status/claim-id.sh`; verified no collision with existing claims (range 0001–9112).

This is the docs-only reconciliation requested: make the repository's canonical stable-context documents accurately reflect evidence ALREADY landed, with exactly one description of the blocker and one ordering of dependencies, and no stale paragraph capable of sending the next agent on an archaeological dig.

**Reconciliation targets (from prompt):**
1. Exact current blocker consistent everywhere: reliable post-MMU access to the already-discovered virtio-pci console transport is required before live RX and a real interactive `dipshit>` session.
2. `docs/march-m15.md` step 17 row says kernel halts at `M2_SERIA` before the monitor runs — check against claim 0015 (post-exit NVRAM console session reaching the shell/commands) and correct if claim still contradicts.
3. Filesystem hard gate was already decided (defer to storage-driver milestone per march step 15); make sure `docs/status.md` no longer presents as unresolved M1.5 acceptance decision.
4. Distinguish mock transcript / NVRAM fallback / real virtio serial TX / live host-to-guest RX evidence; do not let one masquerade as another.
5. Remove or clearly historical-label superseded blocker narratives inside `docs/status.md` (device discovery is next, ExitBootServices is the problem, no usable device exists, kernel still dies before the monitor).
6. Ensure next-work ordering explicit: post-MMU virtio TX first, then virtio RX/live transcript; do not suggest RX can bypass TX/MMU layer.
7. Preserve A/B/C/D evidence classification from `docs/gate-inventory.md`; a portable green build is not VZ evidence.

Scope rules: prefer deleting stale duplicate prose over adding another copy; `docs/status.md` holds milestone-level state, `docs/march-m15.md` holds per-step state, others point to status; do not change milestone scope, invent results, upgrade inferred→observed, rewrite historical claims, or touch hardware code. If two landed claims genuinely conflict, stop and report evidence gap.

Verification: coordination gate, generated-index consistency, relative-link check over changed docs, targeted stale/contradiction grep before/after, audit output under `artifacts/`.

## Contradictions found (audit pre-edit)

Enumerated against current tracked source at `fff37a5`:

1. **Duplicate gate-status table in `docs/status.md`:** lines 43–62 (current Gate status) and lines 64–75 (second table under `### What we directly observe about the two failing gates`) repeat the same gates with stale evidence. The second table's VZ serial row says "serial still silent; marker ladder re-observed 2026-08-07 reaching `M2_SERIA` — device absence, not a crash" — superseded by claims 0013/0020 (device found at BAR `0x100010000`, hang is post-MMU transport access, not device absence). Also contains stale `M2_MAPD!` historical ladder.

2. **`docs/march-m15.md` step 17 — stale `M2_SERIA` halt language:** "the kernel halts at `M2_SERIA` before the monitor runs, so `ResetSystem` is unreachable" — contradicts claim 0015 which records a post-exit NVRAM console session reaching the shell/commands (69–70 chunks, `version`/`mem`/`echo`/`help` output). The monitor DOES run post-exit; `ResetSystem` is unreachable because post-MMU virtio TX hangs, not because the kernel halts at probe.

3. **`docs/status.md` filesystem hard gate — unresolved framing:** ` - [ ] ls, cat, and write persist through reboot — **needs re-scoping**` presents as open acceptance decision; march step 15 already records **Decision: defer fs commands to a storage-driver milestone** (2026-08-06). Status must present as resolved deferred item, not open decision.

4. **Superseded blocker narratives in `docs/status.md` — "What we directly observe about the serial gate..." historical prose:** contains paragraphs that read as current blocker but are superseded: "The serial gate's silence is now explained (claim 0009)... Every VZ run's ladder ends at `M2_MAPD!`" — superseded by claim 0010 (fixed), and "device absence in the declared windows, not a kernel crash" — superseded by claim 0013 (real console outside declared windows, hang is transport access). Must be historical-labeled or removed.

5. **Next-work ordering in `docs/status.md` "What comes immediately afterward":** lists "1. A real RX path" first, without explicit ordering that post-MMU virtio TX must be solved before RX/live transcript. Prompt requires explicit: post-MMU virtio TX first, then RX.

6. **`docs/status.md` Assumptions & gaps — stale "which one wins on VZ is still unobserved" and "[inferred]" MMU/MMI0 claims:** says "which one wins on VZ is still unobserved (the VZ run gate is blocked)" and "MMIO/MMU assumptions stay [inferred]" — superseded: claims 0010/0013/0020/0021 make MMU takeover and device identity [observed]; only register layout stays [inferred].

7. **Gate-inventory vs status evidence distinction — protect A/B/C/D:** status must not let mock transcript or NVRAM fallback masquerade as real virtio TX or live RX. Already largely correct; ensure explicit distinction preserved.

## Corrections (before → after semantics)

1. **Duplicate gate table:** delete second table (lines 64–75) entirely; retain single canonical Gate status table at top. Historical ladder prose moves to a Historical notes collapsible section or is removed if duplicated.

2. **March step 17:** `kernel halts at M2_SERIA before the monitor runs` → `post-MMU virtio transport access hangs, so ResetSystem is not yet reachable post-exit; the monitor does run post-exit via the NVRAM fallback channel (claim 0015)` — fixes contradiction with claim 0015.

3. **Filesystem hard gate:** `needs re-scoping: post-exit there is no ESP...` → `deferred — Decision recorded (march step 15, 2026-08-06): defer `ls`/`cat`/`write`/`touch` to a storage-driver milestone; no ESP post-exit (x3 carries handoff v2); hard gate 5 stays open by design`.

4. **Superseded narratives:** Wrap pre-claim-0010/0013 paragraphs in a Historical notes heading with dates and superseded-by pointers; update any sentence that can be read as "device discovery is next" or "ExitBootServices is the problem" to point to post-MMU transport hang and cite claim 0020 (ExitBootServices exonerated).

5. **Next-work ordering:** Rewrite as ordered dependency: (1) reliable post-MMU access to the already-discovered virtio-pci console transport (TX), (2) virtio RX / live transcript — with note that RX cannot bypass TX/MMU layer.

6. **Assumptions:** Update to reflect observed virtio-pci identity and MMU-takeover completion; keep only register layout as [inferred].

7. **Preserve A/B/C/D** — no change; verify green CI badge does not claim VZ evidence.

## Verification plan

- `bash tools/verify-coordination.sh`
- `bash tools/status/test-coordination.sh`
- relative-link check: `grep -rn '\[.*\](.*\.md)' docs/status.md docs/march-m15.md docs/roadmap.md docs/architecture.md | xargs -I{} verify link target exists`
- stale grep: before/after hits for `device absence|M2_SERIA.*halt|needs re-scoping|ExitBootServices is the problem|no usable device exists|kernel still dies`
- save output under `artifacts/docs-reconciliation-20260808/`
