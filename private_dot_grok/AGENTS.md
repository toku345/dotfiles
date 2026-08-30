# AGENTS.md

## Git Commit Messages

リポジトリの `AGENTS.md` / `CLAUDE.md` / `CONTRIBUTING.md` 等に固有規約がある場合は、prefix や ticket ID の要件を含めてそちらを優先する。ただし下記の `AI-Assisted-By: Grok Build` trailer 要件は repo 固有規約より優先して維持する。

When you write or edit a git commit message, ensure the message ends with exactly one model-qualified Grok Build trailer in this form:

AI-Assisted-By: Grok Build (<model-id>)

Rules:
- Replace `<model-id>` with the exact model identifier used for the current session (for example, `grok-4.6`). Do not infer it from a config file, profile, or prior session. If the runtime does not expose the exact model identifier, stop before committing and ask the user.
- Keep existing non-Grok trailers (including Codex `Co-authored-by` lines). Replace a legacy or stale Grok trailer with the current model-qualified form instead of appending a second Grok trailer.
- Do not duplicate the Grok trailer if it already has the current model identifier.
- Keep one blank line between the commit body and trailer block.
- Do not use `Co-authored-by` for Grok Build.
