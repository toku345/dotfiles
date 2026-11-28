---
name: codex-usage
description: Codex CLI (`codex exec`) による実装計画レビューの条件と手順。厚い変更の計画完成時や、調査委譲・別案試行を検討するときに参照する。adversarial レビューは ~/.claude/agents/adversarial-reviewer と ~/.codex/agents/adversarial-reviewer を使う。
---

# codex-usage

Codex は実装プランの第二意見と長時間調査に使う外部レビュアー兼補助実行系。adversarial コードレビューは chezmoi が配る `~/.claude/agents/adversarial-reviewer` と `~/.codex/agents/adversarial-reviewer` を使う。Claude Code の判断を補強するが、最終採用判断はユーザーが保持する。

別 Codex セッションへの通信は、ユーザーが明示的に頼んだときだけ行う。宛先や自分の agent 名を推測しない。レビュー gate の base pinning / fail-closed aggregation は既存の `$pr-review` / `/pr-review` が担う。

ユーザーが依頼文と結果を編集できる手動の計画レビュー往復を選んだ場合は、skill `plan-review-handoff` の共通手順を使う。

## 用途と起動者

| 用途 | 手段 | 起動者 |
|------|------|--------|
| 実装計画レビュー | `codex exec` via Bash | AI (自動) |
| adversarial コードレビュー | `~/.claude/agents/adversarial-reviewer` と `~/.codex/agents/adversarial-reviewer` | ユーザー (手動) |
| 調査委譲・長時間タスク・別案の試行 | Codex CLI | ユーザー (手動) |

## 実装計画立案時の自動 Codex レビュー

### 実施条件

`codex` 利用可能で、かつ CLAUDE.md「重要度の線引き」の **厚く理解する対象** に該当する変更のときのみ実施する。

軽く扱ってよい対象 (typo / 単純な横展開 / 設定値変更 / 純粋なドキュメント (`docs/**`, `README.md` 等)) には **適用しない**。

ただし**ドキュメント拡張子であっても control plane** に該当する変更は Codex 自動レビュー対象とする。control plane の具体リスト (agent 指示 / skill 定義 / output-styles / shared settings / ADR) は user-global CLAUDE.md (`~/.claude/CLAUDE.md`) `## Definition of Done` § 適用除外 に canonical 定義あり。判定はそちらを参照すること (本 SKILL での再掲は二重定義となり drift 源になるため避ける)。

### 実行手順

1. プラン完成後、当該タスク専用の新規 `codex exec --sandbox read-only -C <repo>` に、元の要求・制約・計画・関連コードや検証の根拠を stdin で渡す（下記の例を参照）。secret・credential・不要な個人情報は渡さない。
2. 依頼文でレビュー専任とし、必要な調査（公式資料・コード・Skill）は許可する。対象の編集・実装・共有リソースの変更・再委譲は禁止し、結果を返して終了させる。調査用ツール・Skill は一律無効化せず、変更・再委譲を伴う Skill は本文参照に留め、既存の権限・承認を維持する。
3. 作成元が指摘の根拠と採否を判断して反映する。必要なら元の要求・制約、修正後の計画、前回指摘と対応を渡した新規プロセスで修正確認する。高優先度の指摘の解消を優先し、nit 等で反復を伸ばさない。
4. 外部レビューは初回と必要な修正確認1回まで。追加確認が必要な重要事項はユーザーに提示する。利用不能・失敗時は外部レビュー未実施を明記してセルフレビューを行う。

### Gotcha: 長い依頼はパイプや既存ファイルから stdin に渡す

`run_in_background: true` で `codex exec "$(cat <<'PROMPT' ... PROMPT)"` のように argv 経由で長い prompt を渡すと、prompt 引数が認識されず `Reading additional input from stdin...` で blocking → 終了する。パイプや既存ファイルから stdin に渡す。呼び出し元が読み取り専用環境では HEREDOC の一時ファイル作成も失敗しうる:

```bash
codex exec --sandbox read-only -C /path/to/repo - < /path/to/request.md
```

## sandbox 注意

`codex exec` / `codex login` は macOS / Linux いずれの sandbox 下でも失敗することがある (macOS: `system-configuration` アクセス制限、Linux: `Read-only file system`)。AI が `dangerouslyDisableSandbox: true` の必要性を判定し Bash 呼び出しに含めるが、最終的な実行は Claude Code の permission prompt 経由で ユーザー が承認する。事前の手動 disable は通常不要。

Linux 側の観測 (2026-09-07、codex-cli 0.153.4 / Claude Code 2.1.263): `dangerouslyDisableSandbox` 未指定・コマンド文字列が `codex --version` のみ、という最小形で `could not create PATH aliases: Read-only file system (os error 30)` が出る (path はメッセージに含まれない)。別途 `~/.codex` は sandbox 内で書き込み不可 (`touch` 失敗、`sandbox.filesystem.allowWrite` に不在)。`codex` は `sandbox.excludedCommands` に入っていない (2026-10-27 に除外を外した)。管理 baseline では sandbox 内で開始し、sandbox 起因の失敗が確認された場合は通常の承認経路で `dangerouslyDisableSandbox` による再実行を検討する。除外や retry は通常の permission 判定を省略しない。

なお `Bash(codex exec:*)` は user-global の `permissions.allow` から外してある。narrow allow rule は auto-mode 分類器より先に解決してしまい、起動オプション (`--sandbox` の有無等) が評価されないため。実行時に承認プロンプトが挟まることがあるが想定内。
