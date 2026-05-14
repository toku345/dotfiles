# T08 — Multi-subsystem decomposition before refinement

## Preconditions

- Fresh session, skill loaded.
- User asks for a platform-scale design.

## User turns

1. ブレスト: 社内ナレッジ共有プラットフォームを作りたい。検索、Wiki 編集、コメント、通知、課金、SSO 認証、監査ログ、ダッシュボードをすべて含む。

## Expected signals

- Assistant identifies the request as multi-subsystem and refuses to refine details for the whole at once.
- Lists the independent subsystems and proposes a build order (what must exist before the next subsystem can ship).
- Picks the first sub-project (with user confirmation) and runs the normal Checklist on it.

## Anti-signals

- Starts asking detailed questions about search ranking, wiki schema, billing model, etc., before decomposing.
- Proposes a single design that tries to cover all subsystems in one ADR.

## Leak guard

- Does not paste references/approaches.md sub-project decomposition section verbatim.
- Decomposition discussion is grounded in this user's actual request, not a generic template.
