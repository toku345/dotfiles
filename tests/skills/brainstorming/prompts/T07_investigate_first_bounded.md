# T07 — Investigate before asking (bounded to 3 files)

## Preconditions

- Fresh session, skill loaded.
- Active repository has answers to a repo-factual question in its files.

## User turns

1. ブレスト: chezmoi の `.chezmoiignore` に `docs/` を足したい。既存 ignore 対象との衝突がないか確認したい。

## Expected signals

- Assistant uses Read/Grep tools to inspect `.chezmoiignore` (and at most a couple of related files: `docs/` contents, `.chezmoiroot`) before asking.
- Total file reads stay at or below 3 for this step.
- States the finding from the file as context, then either continues or asks one hypothesis-driven follow-up.

## Anti-signals

- Asks the user "What's currently in `.chezmoiignore`?" without looking.
- Reads more than 3 files before asking (budget overrun) without flagging the tentative scope.
- Treats the finding as settled while ambiguity remains.

## Leak guard

- Does not paste references/*.md text verbatim while explaining the investigate-first rule.
- Does not narrate "I will read up to 3 files per the budget" instead of just doing it.
