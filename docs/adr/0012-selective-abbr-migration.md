# ADR 0012: Selective abbr Migration for Alias Functions

## Status

Accepted

## Context

Issue #111 proposes migrating all alias functions in `config.fish` to fish shell `abbr` (abbreviations), the officially recommended approach for interactive command shortcuts.

However, `abbr` always expands inline — there is no quiet mode or expansion suppression option. For widely-known shorthand commands like `l`, `ll`, and `tree`, this expansion creates visual noise without adding clarity (e.g., `l` expanding to `eza -ahl --git` on every invocation).

The existing `cm` → `chezmoi` abbreviation confirmed this trade-off in practice: initial disorientation from unexpected expansion, though acceptable for less-frequent, non-obvious shortcuts.

## Decision

Adopt a selective migration strategy based on whether inline expansion adds value:

**Migrate to `abbr`** — shortcuts where the expansion clarifies intent or aids history search:
- `gd` → `git diff-delta`
- `gst` → `git status`
- `d` → `docker`
- `dc` → `docker compose`
- `be` → `bundle exec`

**Keep as functions** — widely-known shorthand where expansion is noise:
- `l` → `eza -ahl --git`
- `ll` → `ls -ahl`
- `tree` → `eza -T`

**Delete** — unused aliases:
- `gp` (git push)

All definitions remain in `config.fish` (no `conf.d/` separation — YAGNI for 6 abbreviations, including the pre-existing `cm`).

This supersedes the "Keep as-is" disposition for `gp`, `gd`, `gst` in [ADR 0004](0004-git-workflow-command-reorganization.md).

## Consequences

- **Positive**: History records full commands for migrated abbreviations; intent is visible at input time; aligns with fish-shell recommendations where appropriate.
- **Positive**: Common ls-family commands remain visually stable — no expansion noise for high-frequency operations.
- **Negative**: Two mechanisms coexist (abbr + function) for simple aliases, requiring a classification judgment for future additions.
- **Constraint**: `abbr` only expands in interactive input ([fish docs](https://fishshell.com/docs/current/cmds/abbr.html): "Only typed-in commands use abbreviations"). Migrated shortcuts cannot be invoked from scripts or `fish -c`. This is acceptable because no script or function in this repository calls them programmatically, and issue #111 lists this as a benefit ("safer").
- **Risk**: History will contain a mix of old function-style entries (`gst`) and new expanded entries (`git status`) during transition. This is cosmetic and resolves over time.
