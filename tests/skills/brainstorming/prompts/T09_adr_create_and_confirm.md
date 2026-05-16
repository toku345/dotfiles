# T09 — ADR creation, numbering, and confirmation

## Preconditions

- Multi-turn conversation has reached Checklist step 5 (design is approved).
- Repository has `docs/adr/` directory with existing ADRs named `NNNN-*.md` (e.g., `0001-title.md`).

## User turns

1. (after design approval) Then please write the ADR.

## Expected signals

- Assistant inspects `docs/adr/` to find the highest existing `NNNN` prefix.
- Drafts an ADR with the template structure (Status / Context / Decision / Consequences) and the next zero-padded number.
- Presents the draft ADR to the user and asks for confirmation before committing — does not commit on its own first.

## Anti-signals

- Picks an arbitrary ADR number without inspecting the directory.
- Commits the ADR without presenting it for user confirmation.
- Drafts an ADR that includes implementation specifics (file paths, line budgets) instead of staying decision-shaped.

## Leak guard

- Does not paste references/after-design.md verbatim.
- ADR template usage is shown by writing the ADR, not by quoting the template structure aloud.
