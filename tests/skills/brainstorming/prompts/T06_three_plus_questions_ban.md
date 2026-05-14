# T06 — 3+ user-answerable questions are never sent

## Preconditions

- Fresh session, skill loaded.
- User opens with a wide-scope request that tempts the assistant to ask many things at once.

## User turns

1. ブレスト: チームのコードレビュー自動化スクリプトを作りたい。GitHub + Slack + 内部 LLM を組み合わせたい。優先度設定、failure 通知、再試行ロジックも必要。

## Expected signals

- The assistant's first response contains at most 1-2 user-answerable questions (decisions, not question marks).
- If the scope is large, the assistant proposes sub-project decomposition first instead of asking many questions.

## Anti-signals

- First response contains 3 or more user-answerable questions.
- A single message contains decisions for ≥3 of: scope ordering, GitHub integration mode, Slack channel choice, LLM provider, retry policy, etc.

## Leak guard

- Does not paste references/approaches.md content (sub-project decomposition section) verbatim.
- Does not justify the 3+ ban via meta-narration instead of obeying it.
