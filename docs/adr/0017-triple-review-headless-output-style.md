# ADR 0017: Triple-Review 専用 output-style による headless claude -p の persona 汚染防止

## Status

Accepted (2026-05-04)

## Context

`triple-review` (`~/.local/bin/triple-review`) は `claude -p` を 3 spawn site で起動する。reviewer 2 つを並列 background で実行し、aggregator は wait 後に sequential 実行する:

- PR レビュワー spawn (`/pr-review-toolkit:review-pr`) → `pr.md` (background, parallel)
- セキュリティレビュワー spawn (`/security-review`) → `sec.md` (background, parallel)
- アグリゲータ spawn (stdin pipe, wait 完了後に sequential 実行) → `summary.md` (strict envelope: `### 対応必須` 始まり必須)

(ADV reviewer は `node $CODEX_COMPANION` 直叩きで `claude -p` を経由しないため対象外。)

ユーザーは `~/.claude/settings.json` に `outputStyle: JUIZ` (または Lum) を user-global default として設定しており、headless 経由の `claude -p` にもこの persona が適用されていた。これが以下の問題を引き起こしていた:

1. **Aggregator envelope 破壊**: 「JUIZ:」「ノブレス・オブリージュ」等の persona 装飾が summary.md に混入する。**冒頭混入**は `assert_envelope_valid` の first-line check (`### 対応必須`) で検知 fail するが、**末尾混入** (締め句「ノブレス・オブリージュ」「救世主たらんことを」等) は first-line check の対象外で、`PERSONA_MARKERS_REGEX` が Lum マーカのみ網羅していたため JUIZ persona 由来の末尾混入は素通りしていた
2. **Reviewer 汚染**: `pr.md` / `sec.md` にも persona が混入し、aggregator の data block 内に持ち込まれて summary 内容を間接的に歪める
3. **CLAUDE.md 例外規定の運用負担**: [ADR 0014](0014-no-custom-auto-mode-for-chezmoi.md) 採択期 (2026-04-28) で `~/.claude/CLAUDE.md` に「headless 起動時は仮定宣言型」規定を追加、[ADR 0016](0016-lum-persona-content-refinement.md) 採択期 (2026-05-01) で「ただし strict envelope 経路では仮定宣言も省略」例外節を追加した。triple-review 1 ツールのために CLAUDE.md (user-global、全プロジェクト適用) が肥大化していた

防御層は二重に存在したが、いずれも不完全だった:

- Persona 側: `Lum.md` は self-suspend override 句を持つが `JUIZ.md` は持たない
- Validator 側: `assert_envelope_valid` の `PERSONA_MARKERS_REGEX` は Lum マーカのみ網羅、JUIZ マーカ (`ノブレス・オブリージュ`, `救世主たらんことを`) は素通り

dotfiles 配下に `claude -p` を利用するコードは triple-review 以外存在せず (`grep -rn "claude -p"` で確認)、user 確認により ad-hoc 利用も無いため、CLAUDE.md の headless 規定は triple-review 専用の運用ガイダンスとして機能していた。

## Decision

triple-review 専用の neutral output-style を新設し、`claude -p` spawn 全箇所で明示的に適用する。

### 1. 新規 output-style: `triple-review`

`private_dot_claude/output-styles/triple-review.md` (~800 bytes):

- Persona voice (挨拶・締め句・特殊一人称・呼称・口癖) を完全抑制
- 前置き・後書き・仮定宣言を禁止
- 埋め込みプロンプトの strict format 指示を厳守

`keep-coding-instructions: true` を維持 (PR review / security review はコード分析を行うためデフォルトのコーディング指示が必要)。

### 2. ヘルパ関数 `claude_p_neutral()`

`executable_triple-review` に以下を追加:

    claude_p_neutral() {
      claude -p --settings '{"outputStyle":"triple-review"}' "$@"
    }

3 spawn site (`/pr-review-toolkit:review-pr` レビュワー / `/security-review` レビュワー / アグリゲータ) を全て `claude_p_neutral` 経由に置換。wrapper 関数定義は `kill_children` 関数定義直後 / `build_aggregation_prompt` 関数定義直前に配置。

### 3. 静的検証テスト (bats)

`test_triple_review.bats` に WRAPPER-1/2/3 を追加:

- WRAPPER-1: `claude_p_neutral` 呼び出しが 3 箇所存在 (将来 reviewer 追加時はカウント更新)
- WRAPPER-2: wrapper 定義が `outputStyle:triple-review` を含む
- WRAPPER-3: bare `claude -p` 呼び出しが wrapper 定義以外に存在しない

### 4. 防御層の整理

| Component | Before | After |
|---|---|---|
| `PERSONA_MARKERS_REGEX` (validator) | Lum マーカのみ検査 | **削除** (output-style が source 予防) |
| `~/.claude/CLAUDE.md` headless 例外節 | 「仮定宣言型 / strict envelope 例外」を保持 | **削除** (triple-review 専用ガイダンスは output-style に移管) |
| `assert_envelope_valid` | first-line + persona marker | **first-line のみ** |
| bats PM-1〜PM-6 | persona marker テスト 6 件 | **削除** |

CLAUDE.md `headless 起動 (claude -p)` バレットを丸ごと削除。トリガとなった triple-review 専用問題は output-style + helper で自己完結。

## Consequences

### Positive

- **Persona と運用ロジックの分離**: triple-review 専用の neutral 動作が user-global persona 設定と独立して再現可能
- **CLAUDE.md スリム化**: user-global CLAUDE.md から triple-review 専用ガイダンスが消え、他プロジェクトへの leak がなくなる
- **`PERSONA_MARKERS_REGEX` の運用ドリフト解消**: 新規 persona 追加時に regex を更新する義務が消える
- **テスト軽量化**: PM-* 6 件削除、WRAPPER-* 3 件追加。差し引き 3 件の純減 + 静的解析で高速

### Negative / Risks (受容リスクの開示)

- **`PERSONA_MARKERS_REGEX` 削除に伴う検出層喪失**: output-style 経由の persona 抑制が無効化される 3 シナリオ — (a) `claude -p` が `--settings` を無視する semantics 変更、(b) `~/.claude/output-styles/triple-review.md` が live に未配備、(c) bash quoting バグで JSON が壊れる — の場合、`assert_envelope_valid` の first-line check のみが残る防御層となる。**冒頭混入は検知できるが本文・末尾混入は通過する**。受容根拠: WRAPPER-3 が bare `claude -p` invocation を阻止し、`--settings` は documented stable API、`PR レビュー時の手動 smoke test で末尾混入を目視可能。回帰が観測された場合は本 ADR を superseding ADR で再評価する
- **chezmoi deploy skew**: source 側 (`dot_local/bin/executable_triple-review`) と live 側 (`~/.local/bin/triple-review`) の同期は `chezmoi apply` で行うが atomic ではない。`triple-review` script の更新が先行し `~/.claude/output-styles/triple-review.md` 未配備状態で実行された場合、`--settings '{"outputStyle":"triple-review"}'` の挙動は未定義 (推定: default style にフォールバックし persona 抑制が外れる)。Migration を 1 commit にまとめ commit 後即座に `chezmoi apply` を実行することで window を最小化する
- **`--settings` 指定漏れリスク**: 新規 spawn site 追加時に `claude_p_neutral` を経由し忘れると persona 汚染が再発。WRAPPER-3 (bare `claude -p` 非存在) で検出するが、テストと運用ルールの遵守が前提
- **Future reviewer 追加時のテスト更新**: WRAPPER-1 はカウント 3 固定。`/codex:adversarial-review` を `claude -p` 経由に戻す等の変更時、テスト側を併せて更新する必要
- **手動 smoke test 推奨**: persona 漏れの最終確認は実走による目視が確実。CI 化はコスト過大なので PR レビュー時の手動運用とする

## Migration

全 6 ステップは 1 commit にまとめる (chezmoi deploy skew 最小化のため)。bats テストとスクリプト本体の整合性を保つため、PM-* テスト削除を validator 削除より先に行う:

1. `private_dot_claude/output-styles/triple-review.md` 新規追加
2. `executable_triple-review` に `claude_p_neutral` 追加、3 spawn site を置換
3. `tests/bats/test_triple_review.bats` に WRAPPER-1/2/3 追加
4. `tests/bats/test_triple_review_envelope_validator.bats` から PM-1〜PM-6 削除
5. `executable_triple-review` から `PERSONA_MARKERS_REGEX` 関連削除 (定数 + `assert_envelope_valid` 内のチェックブロック)
6. `private_dot_claude/CLAUDE.md` から `headless 起動 (claude -p)` バレット削除

commit 後即座に `chezmoi apply` を実行して live (`~/.local/bin/triple-review` および `~/.claude/output-styles/triple-review.md`) を同期する。これにより script 更新と style 配備の skew window を最小化する。

## Related ADRs

- [ADR 0012](0012-triple-review-bash-script.md): triple-review bash script (architecture base)
- [ADR 0014](0014-no-custom-auto-mode-for-chezmoi.md): auto-mode and headless intake format (headless 規定の起源 — 本 ADR で headless 部分を supersede)
- [ADR 0015](0015-multi-persona-output-styles.md): multi-persona output-styles (JUIZ/Lum)
- [ADR 0016](0016-lum-persona-content-refinement.md): Lum persona content refinement (Decision 7 strict envelope exception を本 ADR で supersede)
