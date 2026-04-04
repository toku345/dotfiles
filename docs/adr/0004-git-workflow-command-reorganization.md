# ADR 0004: Git Workflow Command Reorganization

## Status

Accepted

## Context

The dotfiles repository contains several git workflow commands defined as Fish shell functions in `config.fish`: `cc` (worktree creation), `gb` (branch selector), `gbd` (merged branch cleanup), `gc` (checkout), and `gsw` (switch). Several issues motivated a redesign:

- `cc` is an unintuitive command name for worktree creation.
- `gb` does not handle worktree branches (`+` prefix) correctly, causing a P3 regression where branch names starting with `+` are misidentified as worktree markers.
- `gbd` fails to delete worktree-linked branches due to the same `+` prefix parsing issue.
- `gb` allows checking out non-default branches on the main repo even when worktrees exist, which defeats the purpose of worktree isolation.
- `gc` and `gsw` are defined but never used.
- A future need to support Bash on Linux machines means cross-shell portability should be considered.

## Decision

Reorganize the git workflow commands as follows:

**Rename and extend:**

- `cc` → `gw`: Worktree creation with new `-c`/`--checkout` option for idempotent branch checkout (`gw -c <branch>` navigates to existing worktree or creates one; `gw -c <branch> <base>` creates a new branch from base with `--track none` to prevent remote auto-detection).

**Rewrite with new behavior:**

- `gb`: Add worktree protection rule — when on the main repo with worktrees present, block checkout to non-default branches and guide users to `gw -c`. Inside a worktree, allow checkout to the main repo with confirmation and automatic `cd`.
- `gbd`: Use `git branch -D` (not `-d`) for deletion, since merge verification is handled upstream by `git for-each-ref --merged`. This allows `gbd` to work correctly from any branch, not just the default branch.

**Delete:**

- `gc` and `gsw`: Unused, removed without replacement.

**Keep as-is:**

- `gp`, `gd`, `gst`: Simple one-line aliases, remain in shell config.

**Cross-shell strategy:**

- Fish functions are the primary implementation (macOS). Bash equivalents share the same `git for-each-ref` format strings and behavior contracts, with shell-specific code written natively. Since git does the heavy lifting, shell-specific logic is minimal.

**Shared helpers** (Fish autoload functions):

- `__detect_default_branch`: Resolves default branch via `origin/HEAD`, validates existence, falls back through `main`/`master`/`trunk`.
- `__worktree_path_for_branch`: Resolves branch name to worktree directory path via `git worktree list --porcelain`.

**PR #89 disposition:** Close without merging. The `git for-each-ref` approach supersedes the positional parsing fix and test infrastructure from that PR.

## Consequences

- **Positive:** Clearer command naming (`gw`), worktree isolation enforced at the tool level, `gbd` works from any branch, unused commands removed.
- **Positive:** Cross-shell strategy minimizes future duplication — git format strings are the single source of truth for branch classification.
- **Negative:** `cc` users need to retrain muscle memory to `gw`. Since this is a personal dotfiles repository, the migration cost is minimal.
- **Risk:** `git gtr` is an external dependency. If its `--track` flag behavior changes, `gw -c <branch> <base>` could regress. Mitigated by pinning or testing after upgrades.
