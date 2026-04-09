# ADR 0006: Selective abbr Migration for Alias Functions

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

All definitions remain in `config.fish` (no `conf.d/` separation — YAGNI for 6 abbreviations).

## Consequences

- **Positive**: History records full commands for migrated abbreviations; intent is visible at input time; aligns with fish-shell recommendations where appropriate.
- **Positive**: Common ls-family commands remain visually stable — no expansion noise for high-frequency operations.
- **Negative**: Two mechanisms coexist (abbr + function) for simple aliases, requiring a classification judgment for future additions.
- **Risk**: History will contain a mix of old function-style entries (`gst`) and new expanded entries (`git status`) during transition. This is cosmetic and resolves over time.
