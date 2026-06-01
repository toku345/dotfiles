# AGENTS.md

## Global Preferences

- Communicate in Japanese unless the user asks for another language.
- Write git commit messages, GitHub pull request titles/descriptions, and GitHub issue titles/descriptions in English.
- Keep responses concise and practical. State assumptions and blockers explicitly.
- Inspect relevant files before editing, and preserve user changes you did not make.
- Prefer `rg` and `rg --files` for search.
- Run the smallest relevant verification after changes and report whether it passed.
- Use official documentation for OpenAI and Codex facts when exact behavior or freshness matters.

## Code Review Guidelines

- Treat built-in review as the everyday floor and specialist review skills as heavy gates. Do not run heavy multi-agent gates for typo-level or purely mechanical changes.
- Review gates should identify facts that may block merge, not maximize the number of findings. Prioritize concrete user impact, operational risk, security/data-loss risk, or silent false-green risk.
- Do not put nits, style preferences, speculative rewrites, or weakly grounded concerns into the fix queue. Record them as optional suggestions only when they materially help the user.
- For blocker findings, include the affected file/line when available, the observed failure mode, why it matters, and the smallest reasonable fix. If one part is missing but the risk may be severe, call out the missing verification instead of dismissing the issue.
- On re-review, focus on whether prior high-priority (Critical/Important-equivalent) findings were resolved. Raise new findings only when they are clear merge blockers.

## GitHub / Remote Git Auth

- First identify the host's SSH agent path with `ssh -G github.com | rg '^identityagent '`.
- On hosts that use 1Password SSH Agent via `IdentityAgent`, a normal terminal `ssh -T git@github.com` or `git fetch` can succeed while Codex sandboxed commands fail with SSH agent communication errors, `Operation not permitted`, or port 22 sandbox denials.
- On SSH/headless Linux hosts, do not assume access to a desktop 1Password SSH Agent; use the host-specific SSH agent setup unless that host is explicitly configured to run 1Password SSH Agent.
- Do not work around this by adding plaintext private keys unless the user explicitly accepts that security tradeoff.
- For `$pr-review`, prefer fetching the base in a normal terminal and passing an immutable commit SHA to the review: run `git fetch origin refs/heads/main && git rev-parse FETCH_HEAD`, then use `$pr-review --base <sha>` in Codex.
- For remote `git fetch` / `git push` from Codex, use per-command sandbox escalation. For PR/issue metadata, prefer the GitHub connector over `gh` when available.

## Git Commit Messages

When you write or edit a git commit message, ensure the message ends with this trailer exactly once:

Co-authored-by: Codex <noreply@openai.com>

Rules:
- Keep existing trailers and append this trailer at the end if missing.
- Do not duplicate this trailer if it already exists.
- Keep one blank line between the commit body and trailer block.
