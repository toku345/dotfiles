# T01 — English trigger phrase

## Preconditions

- Fresh Claude Code session.
- brainstorming skill installed at user-global scope.

## User turns

1. I want to brainstorm the design for a new tool that helps me sync dotfiles across machines.

## Expected signals

- Skill auto-loads on the English trigger phrase.
- Response begins Checklist step 1 (explore context) or asks a single hypothesis-driven clarifying question.
- Acknowledges design-first framing (no implementation jump).

## Anti-signals

- Skill does not load (description English fallback fails).
- Response jumps straight to code or proposes an implementation.
- Asks 3+ questions in the first message.

## Leak guard

- Response does not paste verbatim text from references/*.md.
- Does not load all three references on startup.
- Does not narrate the Checklist verbatim instead of executing it.
