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

### Dedicated host, never a personal machine

A self-hosted runner executes whatever the workflow tells it to, on the
host it is installed on, with that host's files and credentials. Running
it on a contributor's laptop — including the machine this project is
developed on — makes every job remote code execution against their
personal data, and it puts an always-on inbound service on a machine
that was not chosen for that. Use a throwaway/dedicated Apple silicon
host; the previous runner (`vz-macos27-m4`) was one.

So if the only Apple silicon host available is somebody's personal Mac,
the correct outcome is that class B stays unenforced and is **reported**
as unenforced (that is what the aggregate now does). It is not a reason
to register that Mac. Do not do it, and do not propose it.

### Observed on a hosted runner, 2026-09-14

Probed directly rather than cited from a closed issue. Throwaway workflow,
deleted afterwards; two runs, `34867887781` (sysctls) and `34868404545`
(the hypervisor probe). The `hv_vm_create` column is a direct call to
Hypervisor.framework — what Virtualization.framework is built on.

| runner | macOS | `kern.hv_support` | `hv_vmm_present` | `hv_vm_create(NULL)` |
|---|---|---|---|---|
| `xcode-27` | **27.0 (26A5406e)** | **0** | 1 | **`0xfae9400f` HV_UNSUPPORTED** |
| `macos-latest` | 26.6.2 (25G83) | **0** | 1 | **`0xfae9400f` HV_UNSUPPORTED** |
| *this reference host (control)* | 27.0 | 1 | 0 | `0x00000000` **HV_SUCCESS** |

So the macOS floor **is** satisfied on a hosted runner now — the `xcode-27`
image really is macOS 27 — and it changes nothing. `hv_vmm_present: 1`
says the runner is itself a guest on an M1, GitHub exposes no EL2 beneath
it, and the hypervisor call comes back `HV_UNSUPPORTED`. The surviving
blocker is capability, not version, which is why this doc no longer
blames the hosted macOS release. (The one hosted platform that does
report nested virtualization is Intel; this project's arm64 + macOS 27
contract rules it out.)

The control row is what makes the other two readable: the *same binary
with the same signing*, on the same macOS version, returns success on a
host known to boot guests and `HV_UNSUPPORTED` on a hosted runner.

### Three ways a capability probe lies

All three were hit while producing that table — and each of them, read
wrongly, would have produced a confident and false answer about the host:

- **`<Hypervisor/hv.h>` is x86-only.** On arm64 the umbrella header is
  `<Hypervisor/Hypervisor.h>`; with `hv.h` the probe does not even build.
- **Two different entitlements for two different APIs.**
  Virtualization.framework wants `com.apple.security.virtualization` —
  that is what `host/vm-runner/entitlements.plist` grants, applied by
  `gate_build_runner` in `tools/lib/gate-run.sh`. A direct `hv_vm_create`
  wants `com.apple.security.hypervisor`. Sign with the wrong one and the
  call returns `0xfae94007`, which the SDK's own `hv_error.h` names
  **HV_DENIED**: an answer about the signature, standing in for one about
  the machine.
- **Importing `Virtualization` proves nothing.** The framework links on
  every image, hosted included. Presence of the API is not capability.

So the rule: **a new capability probe needs a positive control** on a host
known to boot guests, or a signing error gets read as a capability verdict
— which is exactly how this probe got two wrong answers before the third
one. `kern.hv_support == 1` stays the contract `vz-gates.yml` asserts.

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

1. On the **dedicated** Mac that will run the gates (any Apple silicon
   host on macOS 27+ that exists to run gates — see the dedicated-host
   rule above; never a contributor's or maintainer's personal machine),
   create a runner:
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
   and confirm shards land on that dedicated host and go green end to
   end (each shard log names the host it ran on).

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
