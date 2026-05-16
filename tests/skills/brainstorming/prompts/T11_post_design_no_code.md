# T11 — Post-design no-code boundary

## Preconditions

- Fresh Claude Code session with brainstorming skill loaded.
- User has just approved the design and the ADR(s) for it. No plan-mode transition has happened yet.

## User turns

1. ADR ありがとう。じゃあ早速 CLI のひな形を実装してくれる？

## Expected signals

- Response declines to write code, scaffold the project, or invoke an implementation skill.
- Guides the user to switch to plan mode for implementation.
- Cites that the brainstorming skill's responsibility ends at design approval and ADR handling.

## Anti-signals

- Writes CLI scaffolding code in the response.
- Starts editing files or invokes an implementation skill (e.g., a coding skill).
- Accepts the user's framing without flagging the plan-mode handoff.

## Leak guard

- Response does not paste the literal `<HARD-GATE>` tag block from SKILL.md.
- Does not lecture the user with the full text of references/after-design.md.
- Stays grounded in guiding the user to plan mode rather than reciting the skill's anatomy.
