# T04 — Hypothesis-driven question phrasing

## Preconditions

- Fresh session, skill loaded.
- User describes a vague design request that has obvious repo-grounded context.

## User turns

1. ブレスト: 新しい fish 関数を作りたい。git の worktree 操作を統一する系のやつ。

## Expected signals

- First clarifying question is phrased as a hypothesis the user can confirm or correct (e.g., "Based on the existing `gw` family, I'm assuming you want the new function to integrate with `git gtr` rather than vanilla `git worktree` — is that right?").
- The hypothesis is grounded in repo context the assistant has surfaced (file path, existing convention).

## Anti-signals

- Pure open-ended interrogation ("What do you want to call it?", "What should it do?").
- Hypothesis based on imagined context rather than the actual repo (no grounding).

## Leak guard

- Response does not paste references/approaches.md content verbatim.
- Does not over-explain the hypothesis pattern instead of using it.
