# ADR 0003: Continuous Integration (CI/CD) and Branch Protection Strategy

- Status: accepted
- Date: 2026-08-05

## Context

DipshitOS development is conducted by both human contributors and autonomous AI agents operating across isolated local worktrees (`calm-lavoisier`, `calm-lavoisier-1`, etc.).

To maintain repository stability, prevent regressions, enforce the rules in `AGENTS.md`, and support parallel development across multiple worktrees, the project requires:
1. Automated CI/CD validation on every push and pull request.
2. Branch protection rules on the central repository (`https://github.com/drawmeanelephant/DipshitOS`).
3. Isolated, short-lived feature/milestone branches for all contributors and agents.

## Decisions

### 1. Dual-Host GitHub Actions CI/CD Matrix

Continuous Integration runs on GitHub Actions using a two-job strategy:

- **`build-and-test-linux` (Ubuntu Latest)**:
  - Cross-compiles the AArch64 UEFI guest app (`boot/src/main.zig`) and freestanding AArch64 kernel (`kernel/src/main.zig`) using Zig 0.16.0.
  - Constructs the FAT32+GPT boot disk image (`zig build image`).
  - Inspects PE32+ headers, EFI subsystem types, COFF section structures, and partition magic (`zig build inspect`).
  - Executes headless QEMU testing (`qemu-system-aarch64` with `qemu-efi-aarch64` / EDK2 firmware).
  - Validates formatting (`zig fmt --check`) and project snapshot generation (`zig build context`).

- **`build-swift-runner-macos` (macOS Latest)**:
  - Validates cross-compilation on Apple Silicon runners.
  - Builds the host Virtualization launcher (`host/vm-runner`) via `swift build`.

### 2. Mandatory Pull Requests & Branch Protection

Direct pushes to the default branch (`main`) are restricted. All contributions (from humans and agents alike) must be submitted via Pull Requests that pass all required status checks (`Build & Test (Linux + QEMU)` and `Build (macOS + Swift Launcher)`).

### 3. Multi-Agent Worktree Branch Conventions

When multiple agents work concurrently in cloned worktrees:
- Agents must operate on dedicated, descriptive feature branches (e.g., `agent/<name>/<milestone>`).
- Agents must verify their work locally using `zig build`, `zig build inspect`, and `zig fmt --check` before opening PRs.
- Merges into `main` require a clean linear history or rebase onto `main`.

## Consequences

- Automated CI prevents broken commits from landing on `main`.
- Parallel agent worktrees can operate independently on feature branches without clashing.
- Every commit on `main` remains verified by automated headless QEMU and binary inspection.
