# Milestone three — ragshit dogfood pass (index, bundle, review)

Planning-first agent prompt for DipshitOS. Feed this file to the
implementing agent. A recurring tooling workstream (prior art: claims
9112, 4922, 0176, 3320, 0019): index the current tree with the local
context engine, emit a milestone-three review bundle, fix any coverage
truncation or ranking gaps found, and dogfood the bundle by reviewing the
new card docs for gaps against the canonical status.

- Branch: `agent/.../m3-ragshit-dogfood` (claim first via `docs/claims/` +
  a log entry in `docs/logs/`; merge per ADR 0003)
- Date: 2026-08-09
- Depends on: — (concurrent-safe: touches `tools/ragshit/` + `artifacts/`
  only; no kernel files, no VZ runs)
- Inputs (read first): `AGENTS.md`, `docs/status.md`, `docs/roadmap.md`,
  `tools/ragshit/README.md` (command set + ranking formula),
  the ragshit prior claims (9112/4922/0176/3320/0019) for the known gaps
  (e.g., 0176 = coverage truncation),
  `docs/m3-syscall-abi-prompt.md`, `docs/m3-march-tracker-prompt.md`,
  `docs/m3-runner-scripted-input-prompt.md`.

## Scope

1. **Index:** `./tools/ragshit/ragshit index .` — confirm the index is
   fresh and complete for the milestone-three surface (kernel/src,
   docs/status.md, docs/roadmap.md, docs/claims/, the new prompt docs).
2. **Bundle:** `./tools/ragshit/ragshit bundle . "milestone three
   userspace syscall ABI" --output artifacts/m3-ragshit-bundle.md` (or the
   equivalent query for the EL0/SVC + syscall-ABI surface).
3. **Fix gaps found:** if the bundle truncates or drops relevant chunks
   (claim 0176's failure mode), fix the engine/configuration in
   `tools/ragshit/` and re-run. Do not hack the bundle by hand.
4. **Dogfood review:** use the bundle to review `docs/m3-syscall-abi-prompt.md`
   against `docs/status.md` + `docs/roadmap.md` — flag contradictions,
   stale references, and missing dependencies (e.g., the EL0/SVC
   depends-on, ADR 0005's runtime-built-table rule, the registry-count
   bump, the transcript-fixture note). Findings go in your branch log and
   as a short "review findings" section in the claim; if a finding is a
   concrete doc fix, propose it — do not edit the prompt docs yourself
   unless trivial (they are the syscall card's contract).
5. **`doctor`:** `./tools/ragshit/ragshit doctor .` passes.

## Do not

- Touch `kernel/`, `tools/verify-*.sh`, `docs/status.md`, or
  `docs/gate-inventory.md` (active-stream files).
- Run any VZ VM or claim any hardware observation.
- Hand-edit the bundle output as evidence; re-run the engine instead.

## Process (hard gate)

1. Claim before you start (claim-id.sh, 🔄), append to your branch log.
2. Index → bundle → fix → review, per above; save output under
   `artifacts/m3-ragshit-*`.
3. Append findings to the branch log; flip the claim to ✅; refresh
   indexes; open a draft PR with `gh` (ADR 0003).

## Definition of done

A fresh index, a complete milestone-three bundle under `artifacts/`, any
coverage/ranking fixes landed in `tools/ragshit/`, a dogfood review of the
syscall-ABI prompt doc with findings logged, `ragshit doctor` green, and
no code outside `tools/ragshit/` changed.
