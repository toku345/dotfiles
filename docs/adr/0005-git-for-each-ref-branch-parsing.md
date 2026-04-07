# ADR 0005: Use git for-each-ref for Branch Parsing

## Status

Accepted

## Context

`git branch` output uses a display-oriented format where the first character is a marker: `*` for the current branch, `+` for worktree-linked branches, and a space for regular branches. Parsing this output is fragile because:

- Branch names can start with `+` or `*`, making marker detection ambiguous (the P3 regression in PR #89).
- PR #89 solved this with positional extraction (`string sub` at fixed offsets), but this requires a dedicated parsing function and test infrastructure.
- `gbd` pipes `git branch --merged` through `grep` and `xargs`, which passes raw marker characters to `git branch -d`, causing failures on worktree branches.

Meanwhile, `git for-each-ref` provides structured, machine-readable output with full control over the format string, including conditional expressions and access to metadata like `%(HEAD)` and `%(worktreepath)`.

## Decision

Use `git for-each-ref --format` with conditional expressions instead of parsing `git branch` output. The format string classifies branches at the git level:

```text
%(if)%(HEAD)%(then)current<TAB>* %(refname:short)
%(else)%(if)%(worktreepath)%(then)worktree<TAB>+ %(refname:short)
%(else)regular<TAB>  %(refname:short)%(end)%(end)
```

This produces TAB-separated `type<TAB>display` output where:

- The type field (`current`/`worktree`/`regular`) is an unambiguous string — no positional parsing needed.
- The display field includes traditional `*`/`+`/space markers for user-facing fzf output.
- Branch name extraction is a fixed 2-character prefix strip from the display field (the prefix is self-generated, not from git's display format).

For `gbd`, a variant format outputs only deletable branch names by emitting empty strings for current and worktree branches, combined with `--merged` filtering:

```text
%(if)%(HEAD)%(then)%(else)%(if)%(worktreepath)%(then)%(else)%(refname:short)%(end)%(end)
```

## Consequences

- **Positive:** The `parse_branch_line` function and its test infrastructure become unnecessary. The P3 bug (branch names starting with `+`) is structurally impossible since type classification happens inside git, not in shell string manipulation.
- **Positive:** `gbd` no longer passes raw marker characters to `git branch -d`. Worktree branches are excluded by the format string's conditional logic.
- **Positive:** The `git for-each-ref` format string is portable across shells — it works identically whether called from Fish, Bash, or any other shell.
- **Negative:** The `git for-each-ref` format string with nested conditionals is harder to read than a simple `git branch` call. This is mitigated by the format being defined once and documented in this ADR.
- **Negative:** Requires git version with `%(worktreepath)` support (git 2.36+, released April 2022). The user's current git version (2.53.0) is well above this threshold.
