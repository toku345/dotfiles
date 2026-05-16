# T03 — One question at the final checkpoint

## Preconditions

- Multi-turn brainstorming conversation reached the final-checkpoint phase (design has been drafted across 1-2 sections and the user is about to give approval).
- Skill loaded and following the Checklist.

## User turns

1. ブレスト: 既存の bats テストハーネスに新しいテストカテゴリを足したい。
2. はい、いまの ghostty 系テストと同じレイアウトで構わない。
3. (scenario-appropriate response to the second clarifying question)
4. では設計を提示して。
5. (after the design is shown) approve it.

## Expected signals

- At the final checkpoint (just before transitioning to ADR writing or plan mode), the assistant message asks exactly one user-answerable question.
- The "decisions per message" count is 1 — not just "question marks per message".

## Anti-signals

- The final-checkpoint message contains 2 or more independent decisions for the user to make.
- A single "question" is actually multiple decisions concatenated with "and" / "かつ".

## Leak guard

- Response does not paste references/*.md content verbatim.
- Does not break the one-question rule by smuggling additional decisions into prose around the question.
