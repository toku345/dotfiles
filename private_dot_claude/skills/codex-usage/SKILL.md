---
name: codex-usage
description: Codex (codex exec / `/codex:adversarial-review` / `/codex:rescue`) の使い分け・自動レビュー条件・`codex exec` / `codex exec resume --last` の構文を提供する。実装プラン完成時に Codex 自動レビューを実施するか判断するとき、長時間調査・別案試行・バックグラウンド実行を検討するときに参照する。
---

# codex-usage

Codex は実装プランの第二意見・adversarial レビュー・長時間調査委譲に使う外部レビュアー兼補助実行系。Claude Code の判断を補強するが、最終採用判断は ユーザー が保持する。

## 用途と起動者

| 用途 | 手段 | 起動者 |
|------|------|--------|
| 実装計画レビュー | `codex exec` via Bash | AI (自動) |
| adversarial コードレビュー | `/codex:adversarial-review` | ユーザー (手動) |
| 調査委譲・長時間タスク・別案の試行 | `/codex:rescue` | ユーザー (手動) |
| バックグラウンド実行管理 | `/codex:status`, `/codex:result` | ユーザー (手動) |

## 実装計画立案時の自動 Codex レビュー

### 実施条件

`codex` 利用可能で、かつ CLAUDE.md「重要度の線引き」の **厚く理解する対象** に該当する変更のときのみ実施する。具体例:

- 複数ファイルにまたがる変更
- アーキテクチャに影響する設計判断
- 既存の振る舞いを変更するリファクタリング

軽く扱ってよい対象 (typo / 単純な横展開 / 設定値変更 / 純粋なドキュメント (`docs/**`, `README.md` 等)) には **適用しない**。

ただし**ドキュメント拡張子であっても control plane** に該当する変更は Codex 自動レビュー対象とする。control plane の具体リスト (agent 指示 / skill 定義 / output-styles / shared settings / ADR) は user-global CLAUDE.md (`~/.claude/CLAUDE.md`) `## Definition of Done` § 適用除外 に canonical 定義あり。判定はそちらを参照すること (本 SKILL での再掲は二重定義となり drift 源になるため避ける)。

### 実行手順

1. プラン完成後、初回レビュー依頼:

   ```bash
   codex exec "...プランレビュー...$(cat <plan>)"
   ```

2. 指摘があれば反映後、再レビュー:

   ```bash
   codex exec resume --last "..."
   ```

3. 再レビューは「新しいレビュー」ではなく、前回の Critical / Important 指摘の検収として扱う。新規指摘は明確な merge blocker に限り、nit / style / optional refactor suggestion を増やして反復ループを伸ばさない。

4. 自動反復は原則 1 回まで。追加反復が必要な場合は、残っている blocker と未検証事項を ユーザー に提示し、続行判断を仰ぐ。

### Gotcha: background + 長い HEREDOC は stdin redirect で渡す

`run_in_background: true` で `codex exec "$(cat <<'PROMPT' ... PROMPT)"` のように argv 経由で長い prompt を渡すと、prompt 引数が認識されず `Reading additional input from stdin...` で blocking → 終了する。HEREDOC は **直接 stdin に redirect** すれば確実:

```bash
codex exec --sandbox read-only -C <dir> <<'PROMPT'
<task>...</task>
PROMPT
```

## sandbox 注意

`codex exec` / `codex login` は macOS sandbox 下で `system-configuration` アクセス制限により失敗することがある。AI が `dangerouslyDisableSandbox: true` の必要性を判定し Bash 呼び出しに含めるが、最終的な実行は Claude Code の permission prompt 経由で ユーザー が承認する。事前の手動 disable は通常不要。
