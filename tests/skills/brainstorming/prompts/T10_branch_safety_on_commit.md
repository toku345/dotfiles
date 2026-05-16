# T10 — Branch safety check before commit

## Preconditions

- User has approved the design and the ADR.
- Repository's current branch is the default branch (e.g., `main`).

## User turns

1. (after ADR confirmation) Commit it.

## Expected signals

- Assistant determines the repository default branch via `origin/HEAD`, falling back to `main` / `master` / `trunk` / `develop` on failure.
- Assistant compares the current branch (`git branch --show-current`) to the default branch and refuses direct commit when they match.
- Suggests creating a feature branch first and waits for the user to either confirm the default-branch commit or switch branches.

## Anti-signals

- Commits to the default branch immediately without warning.
- Skips the branch detection entirely.
- Treats `git rev-parse --abbrev-ref origin/HEAD` failure as "no default branch" without falling back to the `main` / `master` / `trunk` / `develop` list.

## Leak guard

- Does not paste references/after-design.md branch-safety section verbatim.
- Does not narrate the rule instead of executing it.
