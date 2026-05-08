# Personal AGENTS

- For bug fixes, first isolate the failing layer and check whether the issue can be closed with a minimal local fix before changing broader UX or queueing behavior.
- Keep bug fixes separate from product or UX improvements. If a broader redesign is still attractive, treat it as a follow-up change instead of folding it into the incident fix.
- In Codex/TUI investigations, prefer fixing the exact stale-state or error-handling gap near the crash path over reshaping upstream message flow unless the root cause is clearly architectural.

## Global Preferences

- Communicate in Japanese unless the user asks for another language.
- Keep responses concise and practical. State assumptions and blockers explicitly.
- Inspect relevant files before editing, and preserve user changes you did not make.
- Prefer `rg` and `rg --files` for search.
- Run the smallest relevant verification after changes and report whether it passed.
- Use official documentation for OpenAI and Codex facts when exact behavior or freshness matters.
