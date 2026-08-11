# Claim: Milestone-four close-out (full gate re-run, docs reconciliation, milestone tag)

- **Owner:** buffy (`agent/buffy/m4-closeout`)
- **Prompt / plan:** the `m3-userspace` close-out precedent (claim 0707) —
  "Run the complete class-A and class-B suites at the candidate tag,
  reconcile status/roadmap/hardware-contract, and create the milestone tag
  only after every gate passes." Milestone four's per-card work is fully
  landed (cards 1/2/3 + 3a–3g + 4a/4b/4c, merged via PRs #69–#83); the
  roadmap's network sketch makes the close-out an explicit precondition
  ("slots after milestone four closes (the process/IPC foundations are the
  dependency)").
- **Scope:** full class A set (fmt, unit tests, `test-console`, build,
  image, inspect, swift runner build, context, coordination ×2, mmu-debt)
  + full class B set (the complete `verify-vz` aggregate at this HEAD:
  serial takeover, bad-handoff, marker, nvram-console, host-console,
  live-transcript, live-fs, live-gfs, live-timer, live-tasks,
  live-userspace, live-svc, live-uaccess, live-addrspaces, live-lifecycle,
  live-exec, live-args, live-procs, live-concurrent, live-long-lived,
  live-kill, live-sleep, live-entropy, live-reboot, live-ipc,
  live-procs-syscall, live-scale, live-wait); docs consolidation
  (`docs/march-m4.md` close-out row, `docs/status.md` milestone-four row
  flip + gate reverify chain, `docs/roadmap.md` milestone-four-closed
  statement + network row pointer, README, gate-inventory, testing.md
  close-out entry, the completed M4 prompt docs archived to
  `docs/archive/` with live references updated); the milestone tag created
  only after every gate passes.
- **Depends on:** all milestone-four cards landed on `main` at `9d7e4d5`
  (claims 2665/3693/3678/3848/0826/4613/7786/1014/4636/5965/5795/5799/
  3179/9946).
- **Status:** ✅ done 2026-08-11 — **the full class A + class B gate set
  re-ran green at the milestone-four candidate HEAD `9d7e4d5`** (merged
  main after PRs #81/#82/#83; class A 11/11 + class B 28/28; evidence
  `artifacts/gates-reverify-20260811-m4-closeout.txt` +
  `artifacts/m4-closeout-classA-1.log` + the per-gate `vz-live-*` logs).
  Docs reconciled (march-m4 close-out row, status.md milestone row flip +
  gate reverify chain + what-comes-next items 15/16, roadmap
  milestone-four-closed statement + network-row pointer, testing.md
  close-out entry; the 15 completed M4 prompt docs archived to
  `docs/archive/` with the march-m4 links repointed; the next-plan
  `docs/m5-net-tx-prompt.md` stays in root). Milestone tagged
  **`m4-processes`** at the verified commit `9d7e4d5`.

## Notes

**Why this card:** every milestone-four card is landed and merged; the
close-out lane (the claim-0707 pattern) re-runs the entire gate set at a
candidate commit so the tag carries dated evidence, reconciles the living
docs with the landed state, and cuts the milestone tag only when everything
is green. The roadmap's network sketch (card N1, `docs/m5-net-tx-prompt.md`)
starts only after this close-out lands.

**Doc consolidation:** the 15 completed M4 prompt docs still sitting in
`docs/` root (`m4-*-prompt.md`) move to `docs/archive/` per
`docs/archive/README.md`, and the surviving live references (march-m4
prompt links, status pointers) are updated — the claim-0707 pattern. The
active `docs/m5-net-tx-prompt.md` stays in root.

**Verification:** every gate runs at the candidate HEAD `9d7e4d5` on a
clean tree; class A is portable/CI, class B boots real VZ VMs on Apple
silicon (this host). Full transcript saved under `artifacts/`; results
recorded in the status.md gate table and the claim/log indexes; the
milestone tag is created only after the full set is green.
