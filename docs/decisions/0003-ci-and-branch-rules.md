# ADR 0003: Continuous Integration (CI/CD) and Branch Protection Strategy

- Status: accepted
- Date: 2026-08-05

## Context

DipshitOS development is conducted by both human contributors and autonomous AI agents operating across isolated local worktrees (`calm-lavoisier`, `calm-lavoisier-1`, etc.).

The project strictly targets macOS host infrastructure (Apple Silicon + Swift Virtualization.framework).

To maintain repository stability, prevent regressions, enforce the rules in `AGENTS.md`, and support parallel development across multiple worktrees, the project requires:
1. Automated CI/CD validation on macOS runners for every push and pull request.
2. Branch protection rules on the central repository (`https://github.com/drawmeanelephant/DipshitOS`).
3. Isolated, short-lived feature/milestone branches for all contributors and agents.

## Decisions

### 1. macOS-Only GitHub Actions CI/CD Pipeline

Continuous Integration runs on GitHub Actions using a dedicated macOS job (`build-and-test-macos` on `macos-latest`):

- **Guest Compilation**: Cross-compiles the AArch64 UEFI guest app (`boot/src/main.zig`) and freestanding AArch64 kernel (`kernel/src/main.zig`) using Zig 0.16.0.
- **Disk Image Creation**: Constructs the FAT32+GPT boot disk image (`zig build image`).
- **Binary Inspection**: Inspects PE32+ headers, EFI subsystem types, COFF section structures, and partition magic (`zig build inspect`).
- **Host VM Launcher**: Compiles the Swift Virtualization framework launcher (`host/vm-runner`) via `swift build`.
- **Quality Checks**: Validates Zig formatting (`zig fmt --check`) and project snapshot generation (`zig build context`).

### 2. Mandatory Pull Requests & Branch Protection

Direct pushes to the default branch (`main`) are restricted. All contributions (from humans and agents alike) must be submitted via Pull Requests that pass the required status check (`Build & Test (macOS + Swift Launcher)`).

### 3. Multi-Agent Worktree Branch Conventions

When multiple agents work concurrently in cloned worktrees:
- Agents must operate on dedicated, descriptive feature branches (e.g., `agent/<name>/<milestone>`).
- Agents must verify their work locally using `zig build`, `zig build inspect`, `swift build --package-path host/vm-runner`, and `zig fmt --check` before opening PRs.
- Merges into `main` require a clean linear history or rebase onto `main`.

## Consequences

- Automated CI prevents broken commits from landing on `main`.
- Parallel agent worktrees can operate independently on feature branches without clashing.
- Every commit on `main` remains verified by automated macOS builds and binary inspection.
