# Registering a VZ hardware runner (one-time)

The `VZ hardware gates` workflow (`.github/workflows/vz-gates.yml`) runs
the class-B gates — each boots the production image under
Virtualization.framework and asserts observed guest behavior. GitHub has
no hosted macOS 27 image yet (hosted tops out at macOS 26; see the
workflow header), so these gates run on a **self-hosted Apple silicon
macOS 27+ runner**. Until one is registered, the workflow reports
SKIPPED on every PR and push — wired but not enforcing.

> **Status (2026-09-03):** the `vz-macos27-m4` runner was intentionally
> decommissioned and the `VZ_RUNNER_LABEL` variable unset — the workflow
> honestly reports SKIPPED until a runner is re-registered using the
> steps below.

## Why self-hosted

- Gates must observe real VZ hardware behavior; the project's evidence
  rules forbid a check that only pretends (`ci.yml` proves class A only).
- The macOS 27 floor is a documented contract
  (`docs/hardware-contract.md`); relaxing it to fit hosted runners would
  weaken what the green badge means.

## Security note

This repository is public. A self-hosted runner executes whatever the
workflow tells it to, so it must never be exposed to fork PRs. Two
controls enforce that:

- **Repository policy (the hard control):** Settings → Actions → General
  → "Approval for running fork pull request workflows from contributors"
  must stay at its strictest setting so a fork PR's workflow (including
  a fork-modified `vz-gates.yml`) cannot run without an explicit
  maintainer approval. Anyone who can approve a fork run is approving
  arbitrary code execution on the runner host.
- **In-workflow guard (defense in depth):** `vz-gates.yml` skips
  (SKIPPED marker, exit 0) any `pull_request` whose head repository
  differs from this one, so honest forks never reach the runner at all.
  Do not remove that guard, do not add `pull_request_target`, and do not
  reuse this runner label for workflows that run untrusted code.

## Steps

1. On the Mac that will run the gates (any Apple silicon host on macOS
   27+, e.g. a dev machine), create a runner:
   GitHub → repo Settings → Actions → Runners → New self-hosted runner
   → macOS ARM64, then follow the download/config commands it shows.
   The runner registered for this repository is named `vz-macos27-m4`
   with the custom label `vz-macos27`; keep the label if you re-create
   it, and give any replacement runner the same custom label.
2. For unattended enforcement install it as a service so it survives
   reboots and picks work while you're away (the config output prints
   the exact `./svc.sh install` commands; they need sudo). Running
   `./run.sh` in a terminal instead works, but the runner only picks up
   jobs while that process stays alive.
3. Note the labels you gave it at config time (e.g. `self-hosted`,
   `ARM64`, `macos-27`) — or add a custom label like `vz-macos27` for
   clarity.
4. Set the repository variable that points the workflow at it:
   Settings → Secrets and variables → Actions → Variables →
   New repository variable: name `VZ_RUNNER_LABEL`, value = the label
   from step 3 (a custom label is safest; never rely only on shared
   default labels). For the registered runner that value is
   `vz-macos27`.
5. Re-run any recent `VZ hardware gates` workflow from the Actions tab
   and confirm shards land on your machine and go green end to end.

## What enforcement looks like

Once `VZ_RUNNER_LABEL` is set:

- Every PR targeting main gets four shard jobs (~16 class-B gates each,
  ~4 min total locally) plus the aggregate **VZ hardware gates**
  context, which branch protection requires alongside the existing
  class-A checks.
- Gate logs upload as workflow artifacts (`artifacts/vz-ci/<gate>.log`)
  with 14-day retention for post-mortems.
- A wedged boot cannot hang CI: each gate has a 600s watchdog kill.

## Removing / pausing

Delete or blank the `VZ_RUNNER_LABEL` variable — the workflow returns
to SKIPPED mode without any other changes.
