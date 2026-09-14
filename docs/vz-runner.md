# Registering a VZ hardware runner (one-time)

The `VZ hardware gates` workflow (`.github/workflows/vz-gates.yml`) runs
the class-B gates — each boots the production image under
Virtualization.framework and asserts observed guest behavior. They run on
a **self-hosted Apple silicon macOS 27+ runner**.

> **Status (2026-09-14):** no runner is registered (`gh api
> repos/<owner>/<repo>/actions/runners` → `total_count: 0`) and
> `VZ_RUNNER_LABEL` is unset, so the workflow skips every gate. It no
> longer reports that as OK: the aggregate prints **NOT ENFORCED (0 of
> 226 class-B gates ran)**, annotates every run, and writes the reason
> into the run summary. A green required check with nothing to fail on is
> how the class-B fleet went unrun — and `live-sched-ring` stayed red —
> for weeks. The `vz-macos27-m4` runner was decommissioned 2026-09-03.

## Why self-hosted

- **GitHub-hosted runners cannot run class B at all, at any macOS
  version.** Hypervisor.framework is unavailable on them
  ([actions/runner-images#13505](https://github.com/actions/runner-images/issues/13505),
  closed as not planned; its repro asserts `sysctl -n kern.hv_support`
  returns 1, and it fails on those runners), so
  Virtualization.framework cannot boot a guest there.
  This is the durable reason — it does not expire when GitHub ships a
  newer image. (The `xcode-27` hosted image has run macOS 27 itself since
  2026-09-10, and still boots no VM: `ci.yml` uses it to compile against
  the macOS 27 SDK, nothing more.)
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

- Every PR targeting main gets four shard jobs (the 226-member fleet
  split ~57/57/56/56) plus the aggregate **VZ hardware gates** context,
  which branch protection requires alongside the existing class-A
  checks.
- A nightly sweep (`schedule: 0 7 * * *`) re-runs the whole fleet on its
  own cadence, so drift that no PR happens to provoke still surfaces
  without waiting for someone to edit the repo.
- Gate logs upload as workflow artifacts (`artifacts/vz-ci/<gate>.log`)
  with 14-day retention for post-mortems.
- A wedged boot cannot hang CI: each gate has a 600s watchdog kill.

## Removing / pausing

Delete or blank the `VZ_RUNNER_LABEL` variable — the workflow returns
to SKIPPED mode without any other changes.
