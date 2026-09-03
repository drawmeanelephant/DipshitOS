# VirelaiOS Branch Protection & Multi-Agent Workflow Guide

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
      - Search and select the status check (matches the job name in
        `.github/workflows/ci.yml`):
        - `Build (macOS + Swift Launcher)`
    - [x] **Require linear history** (prevents merge commits, keeps `git log` clean).
    - [x] **Do not allow bypassing the above settings** (applies to administrators as well).

> **Reality check (2026-08-24):** main is protected by a repository
> **ruleset** ("Protect your neck", id `20482368`), not classic branch
> protection: deletion + non-fast-forward, PR required (0 approvals), and
> the required check `Build (macOS + Swift Launcher)`.

### Merge queue on main (issue #523 item 6) — BLOCKED by plan, config ready

Goal: force every PR's required check to run against the STACKED merged
state (merge trains), because textual merges of large files can be clean
yet semantically broken.

Observed 2026-08-24 (claim 0680): adding a `merge_queue` rule via the REST
rulesets API fails with `Invalid rule 'merge_queue'` for this repository —
also on a disabled probe ruleset targeting a dummy branch. The feature is
not available on this account's current plan (GitHub makes merge queues a
Team/Enterprise feature). No partial state was left: the ruleset is
unchanged.

When the plan allows it, enable in one step — Settings → Rules → Rulesets →
"Protect your neck" → add a **Require merge queue** rule:

| Parameter | Value |
|-----------|-------|
| Grouping strategy | `ALLGREEN` |
| Merge method | `Merge` |
| Min entries to merge | 1 |
| Max entries to merge | 3 |
| Min wait minutes | 1 |
| Max entries to build | 3 |
| Check response timeout | 60 min |

…and tick **Require branches to be up to date before merging** on the
required-check rule (`strict_required_status_checks_policy: true`).

Or via API (the call that was attempted; it will succeed once the plan
qualifies):

```bash
gh api -X PUT repos/drawmeanelephant/DipshitOS/rulesets/20482368 --input - <<'EOF'
{
  "name": "Protect your neck",
  "target": "branch",
  "source_type": "Repository",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
  "rules": [
    {"type": "deletion"},
    {"type": "non_fast_forward"},
    {"type": "pull_request", "parameters": {
      "allowed_merge_methods": ["merge", "squash", "rebase"],
      "dismiss_stale_reviews_on_push": false,
      "require_code_owner_review": false,
      "require_extra_approval_for_unattributed_changes": true,
      "require_last_push_approval": false,
      "required_approving_review_count": 0,
      "required_review_thread_resolution": false,
      "required_reviewers": []}},
    {"type": "required_status_checks", "parameters": {
      "do_not_enforce_on_create": false,
      "required_status_checks": [
        {"context": "Build (macOS + Swift Launcher)", "integration_id": 15368}],
      "strict_required_status_checks_policy": true}},
    {"type": "merge_queue", "parameters": {
      "check_response_timeout_minutes": 60,
      "grouping_strategy": "ALLGREEN",
      "max_entries_to_build": 3,
      "max_entries_to_merge": 3,
      "min_entries_to_merge": 1,
      "min_entries_to_merge_wait_minutes": 1,
      "merge_method": "MERGE"}}
  ]
}
EOF
```

Interim mitigation (already practiced): merge-prep claims re-verify the
branch after folding origin/main in (see claim 2259, historical), and the
coordination gate (`tools/status/verify-issue-coordination.sh`) blocks
overlapping active claim issues before CI ever sees them.

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
   Before pushing, the agent must execute and pass (`just verify` runs the
   whole sequence):
   ```bash
   zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig
   bash tools/verify-unit-tests.sh
   zig build test-console
   zig build
   zig build image
   zig build inspect
   swift build --package-path host/vm-runner
   zig build context
   bash tools/status/verify-issue-coordination.sh
   bash tools/lint-workflows.sh
   ```

3. **Submitting Work**:
   Push the feature branch to GitHub and create a Pull Request:
   ```bash
   git push -u origin agent/<agent-id>/<feature-name>
   ```

4. **Merging to `main`**:
   Once GitHub Actions CI passes (`Build (macOS + Swift Launcher)` — the
   sole status check), rebase or merge the PR into `main`.

5. **Updating Other Worktrees**:
   In other worktree instances, pull the updated `main` branch:
   ```bash
   git checkout main
   git pull origin main
   ```
