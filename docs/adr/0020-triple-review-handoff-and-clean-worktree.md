# ADR 0020: triple-review の auto-handoff payload 拡張と clean-worktree pre-flight guard

## Status

Accepted (2026-05-08, revised 2026-05-08).

**Revision (2026-05-08, post-merge dogfooding)**: scope of `require_clean_worktree` expanded from `--untracked-files=no` (tracked-only) to `--untracked-files=normal` (tracked-modified + untracked-non-ignored). The original Decision tolerated untracked silent skip on the assumption that "the user is expected to `git add` first", but the Codex adversarial review of the implementation PR (#191) flagged this as [high] — in this dotfiles repo, new files (dotfiles, scripts, configs) are routinely added before review, and the tracked-only scope reproduced the same Vector 2 silent-failure mode the guard was meant to close. The in-place revision aligns the guard with the Issue #186 fail-closed-default philosophy.

## Context

triple-review (`~/.local/bin/triple-review`) のレビュー結果が auto-handoff session で十分に活かされない 2 つの精度低下 vector が、独立 2 ソース (in-session brainstorm + Codex CLI cross-check) の調査で確認された。

### Vector 1 — handoff payload が `summary.md` のみ

`exec claude --` に渡される handoff payload には集約済みの `summary.md` だけが含まれ、3 つの raw レビュー (`pr.md` / `sec.md` / `adv.md`) は付与されない (`executable_triple-review:1081`)。

aggregator prompt は明示的に「Raw レビューをそのまま転記せず、統合・重複排除・優先度判定した結果だけを出力してください」と要求し (`executable_triple-review:788`)、severity classifier は「2 名以上の指摘 OR 単独でも致命系 (セキュリティ / データ損失 / クラッシュ / 機密情報漏洩)」だけを「対応必須」に昇格、それ以外は「要検討」に降格する (`executable_triple-review:771-775`)。

結果として handoff session の Claude は **集約された圧縮 view から対応案を提案する**ことになり、reviewer 個別のコード snippet・根拠記述・ニュアンスを参照できない。raw 3 ファイルは `$TMPDIR/triple-review-XXXXXX/` に残り、stdout にも全文が流れているが、handoff session 自身が能動的に読みに行く動線は提供されていなかった。

### Vector 2 — 3 reviewer すべてが committed diff のみ対象

3 reviewer の scope は一貫して **commit 済みの branch/PR diff** に限定される:

- Codex ADV: `--scope branch` 明示 (`executable_triple-review:898`)
- `/pr-review-toolkit:review-pr` / `/security-review`: 内部で `gh pr view` ベースに scope 検出 (ADR 0012 §"Known limitation — scope alignment" 参照)

dirty worktree (未コミット tracked 変更あり) の状態で triple-review を実行すると、その変更は **silently 全 reviewer から除外される**。warn も err もないため、ユーザーは「reviewer が未コミット変更も見ている」前提で summary を信用してしまう。Issue #186 の fail-closed 化 (PR 必須 + partial-failure abort) と同種の silent-degradation pattern であり、同じ哲学で fail-closed にすべき。

## Decision

### 1. auto-handoff prompt に raw paths section を追記

`exec claude --` の payload 末尾に raw 3 ファイルのパス参照を追加し、on-demand Read を促す形にする。argv の inline 肥大化は回避:

```bash
exec claude -- "${handoff_prefix}$(cat "$workdir/summary.md")

上記の 対応必須 / 要検討 項目への対応方針を提案してください。

Raw reviewer outputs (具体的なコード snippet や、要約で圧縮された指摘の原典を確認したいときだけ Read で取得):
- $workdir/pr.md
- $workdir/sec.md
- $workdir/adv.md"
```

`summary.md` 本体は変更しない (envelope validator `assert_envelope_valid` は `summary.md` の first non-blank line だけを検査するため、envelope contract は完全に維持される)。

### 2. clean-worktree pre-flight guard を `check_prerequisites` に追加

新関数 `require_clean_worktree` を追加。tracked-modified + untracked-non-ignored を検出で fail-closed:

```bash
require_clean_worktree() {
  local dirty
  dirty=$(git status --porcelain --untracked-files=normal 2>/dev/null) \
    || err "git status failed; cannot verify worktree cleanliness."
  if [ -n "$dirty" ]; then
    err "Worktree has uncommitted changes:
$dirty
triple-review reviews PR/branch diffs only — uncommitted changes (tracked-modified or untracked-non-ignored) will NOT be reviewed.
Commit or stash first, then retry."
  fi
}
```

設置位置は `check_prerequisites` の `git rev-parse --is-inside-work-tree` チェック直後 (`executable_triple-review:284` の後)。

`--untracked-files=normal` 指定で tracked-modified と untracked-non-ignored の両方を block し、`.gitignore`-honored ファイル (build artifact / editor swap file / `.DS_Store` 等の OS noise) は引き続き ignore して通過させる。Original Decision は `--untracked-files=no` (tracked-only) だったが Status section の Revision note 参照。

### 3. opt-out flag は導入しない

`--allow-dirty` 等の opt-out flag は当面追加しない (YAGNI)。実際に「dirty でも走らせたい」ユースケースが具体化したら future ADR で追加を検討する。既存の `--allow-no-pr` / `--allow-partial` パターンとの対称性は認識した上で、現時点で実需が観測されないため surface area を増やさない判断とする。

## Consequences

### Positive

- handoff session が aggregator の compression loss を ad-hoc に補える (Read 指示が明示されているため、必要に応じて raw を参照する動線が確立)
- 「reviewer は uncommitted を見ない」silent failure mode を機械的に排除
- 既存の fail-closed default (Issue #186 の `--allow-no-pr` / `--allow-partial`) と一貫した設計哲学
- 両変更とも triple-review 内に閉じている — output-style / plugin / upstream の協調変更が不要 (chezmoi deploy skew リスクなし)

### Negative / Risks

- **argv 増加**: 3 paths × ~80 bytes ≈ 240 bytes。Linux ARG_MAX (~2MB) からは無視可能
- **`.gitignore`-honored ファイルは untracked passthrough**: build artifact / editor swap file / OS-specific file (`.DS_Store` 等) は `.gitignore` 経由で guard をすり抜ける。意図せずレビュー対象に含めたい場合は `.gitignore` の見直しが必要 — git 標準の hygiene と整合する設計。逆に意図的に除外したい新規ファイルは `.gitignore` 追加で対応
- **反復作業中の friction 増**: 反復的に triple-review を回すワークフロー (commit せず複数回試す等) は dirty guard で中断される。`--allow-dirty` の future 追加で緩和可能だが現時点では deferred
- **handoff prompt の Read 指示は heuristic**: Claude session が指示を無視しても enforcement する手段はない。aggregator 段階での compression loss を完全に解消するわけではなく、「raw を必要に応じて読みに行ける動線」を提供するに留まる
- **dirty 中の WIP review が break**: triple-review を「draft PR push 後 → 走らせる」に揃える運用が default になる。これは既存の "PR 必須" default (Issue #186) と同じ哲学なので一貫性は保たれる

### Bats coverage

`tests/bats/test_triple_review.bats` に以下を追加:

| ID | 内容 |
|---|---|
| DIRTY-1 | tracked-modified file で `check_prerequisites` 段の guard が err 中断 (exit 1) |
| DIRTY-1B | untracked-non-ignored file で guard が err 中断 (Status revision で追加) |
| DIRTY-2 | `.gitignore`-honored untracked file は guard を通過 (= `--untracked-files=normal` でも ignored は素通りすることの検証) |
| DIRTY-3 | `git status` 自体が失敗する病的ケースで err 中断 (`|| err` の動作確認) |
| HANDOFF-1 | `exec claude --` の handoff payload に 3 ファイルパスの参照が含まれる (静的 source assertion) |

実装後に `bats-docker-parity-runner` subagent で Ubuntu 24.04 parity を確認する。新規テストは pure bash + `git status` + `claude` stub のみで完結し、Node.js 依存を持たないため、過去の Node 18 互換性問題 (PR `8dc20f0` / `73ed518` で解決済) とは独立に動作する。

## Related ADRs

- [ADR 0012](0012-triple-review-bash-script.md): triple-review base architecture。本 ADR は ADR 0012 Decision section の "Auto-handoff" を refine し、`check_prerequisites` に新たな確認項目を 1 つ追加する
- [ADR 0017](0017-triple-review-headless-output-style.md) / [ADR 0019](0019-headless-strict-envelope-general-rule.md): persona suppression / headless guidance。独立した別ドメインの決定で、本 ADR と直接の overlap はない
- [ADR 0018](0018-restrict-auto-mode-override-to-non-interactive.md): auto-mode override gating。関連性なし

## 影響ファイル

- `dot_local/bin/executable_triple-review` (`require_clean_worktree` 追加 + `exec claude --` payload に raw paths section 追記)
- `tests/bats/test_triple_review.bats` (DIRTY-1/2/3 + HANDOFF-1 追加)
- `docs/adr/0020-triple-review-handoff-and-clean-worktree.md` (本 ADR)
