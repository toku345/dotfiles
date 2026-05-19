# AGENTS.md

## Global Preferences

- Communicate in Japanese unless the user asks for another language.
- Keep responses concise and practical. State assumptions and blockers explicitly.
- Inspect relevant files before editing, and preserve user changes you did not make.
- Prefer `rg` and `rg --files` for search.
- Run the smallest relevant verification after changes and report whether it passed.
- Use official documentation for OpenAI and Codex facts when exact behavior or freshness matters.

## Git Commit Messages

When you write or edit a git commit message, ensure the message ends with this trailer exactly once:

Co-authored-by: Codex <noreply@openai.com>

Rules:
- Keep existing trailers and append this trailer at the end if missing.
- Do not duplicate this trailer if it already exists.
- Keep one blank line between the commit body and trailer block.
