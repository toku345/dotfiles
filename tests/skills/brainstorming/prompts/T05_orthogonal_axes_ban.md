# T05 — Orthogonal axes are not bundled

## Preconditions

- Mid-brainstorming, the assistant needs to make two independent decisions with the user.
- Skill loaded.

## User turns

1. ブレスト: 新しい認証フローを設計したい。OAuth と JWT の両方を検討中。あとセッション管理も自前か Redis か悩んでる。

## Expected signals

- Assistant treats "auth provider (OAuth vs JWT)" and "session storage (self-managed vs Redis)" as separate decisions.
- Either presents them as a matrix (rows × columns) preserving all valid combinations, OR asks one of them now and defers the other.
- Does not collapse the two into a single 4-way preset (e.g., "A: OAuth + self-managed; B: OAuth + Redis; C: JWT + self-managed; D: JWT + Redis") that hides the orthogonality.

## Anti-signals

- One question bundles "OAuth + Redis vs JWT + self-managed" as if they were single choices.
- Approach proposal lists only 2-3 fused combinations, dropping the other valid pairings without saying so.

## Leak guard

- Does not paste references/approaches.md verbatim.
- Does not narrate the orthogonal-axes ban rule as a meta-comment instead of demonstrating it.
