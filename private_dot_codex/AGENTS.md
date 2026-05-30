# AGENTS.md

## Global Preferences

- Communicate in Japanese unless the user asks for another language.
- Keep responses concise and practical. State assumptions and blockers explicitly.
- Inspect relevant files before editing, and preserve user changes you did not make.
- Prefer `rg` and `rg --files` for search.
- Run the smallest relevant verification after changes and report whether it passed.
- Use official documentation for OpenAI and Codex facts when exact behavior or freshness matters.

## Code Review Guidelines

- Treat built-in review as the everyday floor, specialist review skills as heavy gates, and coaching workflows as learning aids. Do not run heavy multi-agent gates for typo-level or purely mechanical changes.
- Review gates should identify facts that may block merge, not maximize the number of findings. Prioritize concrete user impact, operational risk, security/data-loss risk, or silent false-green risk.
- Do not put nits, style preferences, speculative rewrites, or weakly grounded concerns into the fix queue. Record them as optional suggestions only when they materially help the user.
- For blocker findings, include the affected file/line when available, the observed failure mode, why it matters, and the smallest reasonable fix. If one part is missing but the risk may be severe, call out the missing verification instead of dismissing the issue.
- On re-review, focus on whether prior Critical/Important findings were resolved. Raise new findings only when they are clear merge blockers.

## Git Commit Messages

When you write or edit a git commit message, ensure the message ends with this trailer exactly once:

Co-authored-by: Codex <noreply@openai.com>

Rules:
- Keep existing trailers and append this trailer at the end if missing.
- Do not duplicate this trailer if it already exists.
- Keep one blank line between the commit body and trailer block.
