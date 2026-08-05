# DipshitOS Branch Protection & Multi-Agent Workflow Guide

This document outlines the recommended branch protection configuration for the GitHub repository (`https://github.com/drawmeanelephant/DipshitOS`) and details best practices for multi-agent parallel development.

---

## 1. GitHub Branch Protection Setup

To enforce quality and prevent broken code from reaching the `main` branch, configure GitHub Branch Protection Rules as follows:

### Step-by-step Configuration in GitHub:

1. Navigate to your repository on GitHub: `https://github.com/drawmeanelephant/DipshitOS`.
2. Click on **Settings** -> **Branches** (or **Rules** -> **Rulesets**).
3. Click **Add branch protection rule** (or **New ruleset** -> **New branch ruleset**).
4. Set **Branch pattern name** to `main`.
5. Enable the following settings:

   - [x] **Require a pull request before merging**
     - Require approvals: 1 (optional for solo dev + AI agents, but PR requirement should remain on).
     - Dismiss stale pull request approvals when new commits are pushed.
   - [x] **Require status checks to pass before merging**
     - Check **Require branches to be up to date before merging**.
     - Search and select the following status checks:
       - `Build & Test (Linux + QEMU)`
       - `Build (macOS + Swift Launcher)`
   - [x] **Require linear history** (prevents merge commits, keeps `git log` clean).
   - [x] **Do not allow bypassing the above settings** (applies to administrators as well).

---

## 2. Multi-Agent Worktree Guidelines

When operating multiple AI agents in parallel (e.g. across worktrees `calm-lavoisier`, `calm-lavoisier-1`, `calm-lavoisier-2`, `calm-lavoisier-3`):

### Workflow Rules for Agents:

1. **Never commit directly to `main`**:
   Before starting work, the agent must create and switch to a feature branch:
   ```bash
   git checkout -b agent/<agent-id>/<feature-name>
   ```

2. **Pre-Push Local Verification**:
   Before pushing, the agent must execute and pass:
   ```bash
   zig fmt --check boot/src/main.zig kernel/src/main.zig build.zig
   zig build
   zig build image
   zig build inspect
   ```

3. **Submitting Work**:
   Push the feature branch to GitHub and create a Pull Request:
   ```bash
   git push -u origin agent/<agent-id>/<feature-name>
   ```

4. **Merging to `main`**:
   Once GitHub Actions CI passes (`Build & Test (Linux + QEMU)` & `Build (macOS + Swift Launcher)`), rebase or merge the PR into `main`.

5. **Updating Other Worktrees**:
   In other worktree instances, pull the updated `main` branch:
   ```bash
   git checkout main
   git pull origin main
   ```
