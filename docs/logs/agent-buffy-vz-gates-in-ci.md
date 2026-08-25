# Log — `agent/buffy/vz-gates-in-ci`

## 2026-08-25 — class-B VZ gates wired into CI as a required check

Goal: automerge must not be able to land code that only passes host
(class-A) tests. The two hardware-only bugs found by claim 5220 (`which`
const-table abort, DEVCONS BSS crash) both shipped past full green CI —
the fix is making the live gates part of the merge contract.

Constraint discovered up front: GitHub-hosted runners top out at macOS
26 (`xcode-27` preview image), and VMRunner enforces the project's
documented macOS 27+ floor at runtime — so hosted CI physically cannot
boot the guest today.

Design (staged enforcement):
- `.github/workflows/vz-gates.yml`: shards every class-B gate from the
  GATE_INVENTORY block ×4 across `vars.VZ_RUNNER_LABEL` (65 gates after
  excluding interactive-only serial-takeover; ~11 s/gate locally →
  ~4 min/shard ceiling is generous). Per-gate 600s watchdog kill;
  per-shard logs uploaded as artifacts; aggregate **VZ hardware gates**
  job for branch protection.
- Until an Apple silicon macOS 27+ self-hosted runner is registered and
  named by `VZ_RUNNER_LABEL`, shards run on a fallback runner and exit 0
  with a visible SKIPPED notice — wired but honestly not enforcing.
- `.github/workflows/ci.yml`: honesty header updated — class-B now runs
  in vz-gates.yml, not "nowhere".
- `docs/vz-runner.md`: one-time registration guide incl. the public-repo
  fork-PR security note (no pull_request_target, ever).
- Pointers: docs/gate-inventory.md machine-readable section,
  docs/status.md gate table (🔶 wired/skipped row).

Touches: .github/workflows/ci.yml (edited),
.github/workflows/vz-gates.yml, docs/vz-runner.md,
docs/gate-inventory.md, docs/status.md (all new/edited by this branch
only).
