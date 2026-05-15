# Proposing approaches

Read this file before Checklist step 3 (propose 2-3 approaches).

## Propose 2-3 approaches

Once you understand the requirement well enough, surface 2-3 distinct ways to solve it before settling. Don't ask the user to choose blindly: lead with your recommended option and explain why, then describe the alternatives so the user can override.

## Trade-off table format

For non-trivial decisions, present a small Markdown table so trade-offs are visible at a glance:

```
| Approach | Pros | Cons |
| --- | --- | --- |
| A. <name> | <one phrase> | <one phrase> |
| B. <name> | <one phrase> | <one phrase> |
```

Keep cells short. If a trade-off needs a paragraph to explain, lift it into the prose above the table — tables that overflow stop being scannable.

## Recommendation framing

Phrase the recommendation as a hypothesis the user can confirm or correct: "I'd lean toward A because of X — does that match your priorities?" rather than "Which one do you want?". This lets a one-question-per-message check still hold while exposing alternatives.

## Strongest-objection check (visible)

Before locking in the recommended option, articulate the strongest objection to it in plain text. Make this visible to the user — not an internal note. Example: "The biggest risk with A is <X>. If <X> is unacceptable, B becomes the right choice." Silent objection-checks are not enough; the user must see the failure mode you considered.

## 2-vs-3 heuristic

- **2 approaches** is enough when the decision space is bimodal (e.g., "stay with current approach vs. rewrite", "do it in-tree vs. extract").
- **3 approaches** earns its keep when there is a meaningful middle ground or a genuinely different mental model worth surfacing.
- More than 3 dilutes the table and rarely helps; collapse near-duplicates into a single approach with a parenthetical variant.

## Sub-project decomposition

If the request spans multiple independent subsystems (e.g., "build a platform with chat, file storage, billing, and analytics"), do not propose approaches for the whole. Instead:

1. Name the independent pieces and how they relate.
2. Suggest a build order (what must exist before the next subsystem can ship).
3. Pick the first sub-project and run the normal Checklist on it.

Trying to design the whole platform in one round dilutes everything.
