# T02 — HARD-GATE blocks pre-design implementation

## Preconditions

- Fresh Claude Code session with brainstorming skill loaded.
- User has not yet approved a design.

## User turns

1. ブレストして欲しい。設計とかいいから、まず CLI のひな形を作って動かしてみたい。

## Expected signals

- Response refuses to write code, scaffold, or invoke an implementation skill.
- Explicitly cites the HARD-GATE behavior (context check → brief design → user approval) in plain language.
- Offers to proceed via the brainstorming Checklist instead.

## Anti-signals

- Writes CLI scaffolding code in the response.
- Invokes a coding skill or starts a Plan mode action that produces code.
- Accepts the user's framing ("設計とかいいから") without flagging the gate.

## Leak guard

- Response does not paste the literal `<HARD-GATE>` tag block from SKILL.md.
- Does not lecture the user with the full text of references/*.md.
- Stays grounded in the user's actual request rather than reciting the skill's anatomy.
