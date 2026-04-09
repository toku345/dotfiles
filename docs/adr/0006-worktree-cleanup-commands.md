# ADR 0006: Worktree Cleanup Commands (`gw rm` / `gw clean`)

## Status

Accepted

## Context

With the worktree protection rule introduced in #122, feature branch work now always happens in worktrees. The typical lifecycle is: `gw -c feature` → work → merge PR → cleanup. Currently, cleanup requires invoking `git gtr rm <branch> --delete-branch` directly. As worktree usage increases, a streamlined cleanup interface integrated into the existing `gw` command becomes valuable (Issue #124).

Key forces:

- `gw` already acts as a dispatcher (`-c`, `--help`), so adding subcommands is natural
- `git gtr rm --delete-branch` already handles worktree + branch deletion in one step
- `gbd` handles non-worktree merged branch cleanup and remains useful for small repos without worktrees
- Users need a way to clean up both individual worktrees and batch-clean merged ones

## Decision

Add two subcommands to `gw`:

### `gw rm <branch> [--force]`

- Verifies the branch has an associated worktree before proceeding; errors immediately if not found
- If the user is currently inside the target worktree, automatically `cd` to the main repo toplevel before deletion (required because `git worktree remove` fails from inside the target)
- Delegates to `git gtr rm <branch> --delete-branch --yes [--force]` (worktree + branch deletion)
- `--force` passes through to `git gtr rm` to allow removing worktrees with uncommitted changes
- Uses existing `__worktree_path_for_branch` for worktree path lookup
- `git gtr rm` returns exit 0 even on failure, so `__gw_rm` checks worktree existence after the call to detect actual failure and emits an error message

### `gw clean [--force]`

- Detects worktree-linked branches merged into the default branch using `git for-each-ref --merged=$base` with format `%(if)%(worktreepath)%(then)%(refname:short)%(end)` (selects branches that have a worktree path, regardless of `%(HEAD)`; unlike `gbd`'s format, `%(HEAD)` is intentionally not checked so that the current worktree's branch is included in cleanup)
- Excludes the main worktree's branch by reading only the first block of `git worktree list --porcelain` (stops at the first blank line); in detached HEAD state, the main worktree has no `branch` line, so nothing is excluded
- Displays the list and prompts for confirmation (`[y/N]`, default No)
- Delegates each deletion to `__gw_rm` (reuses cd-out-of-worktree logic and error detection)
- On failure, skips the failed branch and continues with remaining branches; returns non-zero if any removal failed
- `--force` passes through to `__gw_rm` for dirty worktrees
- No `--dry-run` flag; the confirmation prompt serves the same purpose

### What is NOT changed

- `gbd` remains as-is for non-worktree branch cleanup
- No separate commands (`gwrm`, `gwc`); subcommands under `gw` keep the namespace unified

### Implementation structure

- `__gw_rm` and `__gw_clean` as separate files under `functions/`, following the `__gw_checkout` pattern
- `gw` function gains two additional dispatch branches (minimal change)

## Consequences

- **Positive**: Single-step worktree cleanup. `gw clean` → `gbd` covers all merged branch cleanup
- **Positive**: Consistent UX — all worktree operations live under `gw`
- **Risk**: Dependency on `git gtr rm --delete-branch` behavior (same level of coupling as existing `gw -c`)
- **Future**: `gb`/`gbd` could eventually be unified under a similar subcommand pattern
