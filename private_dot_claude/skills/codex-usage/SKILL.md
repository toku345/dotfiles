---
name: codex-usage
description: Codex CLI による実装計画レビューの条件と手順、および `/codex:adversarial-review` / `/codex:rescue` の使い分け。厚い変更の計画完成時や、調査委譲・別案試行・バックグラウンド実行を検討するときに参照する。
---

# codex-usage

Codex は実装プランの第二意見・adversarial レビュー・長時間調査委譲に使う外部レビュアー兼補助実行系。Claude Code の判断を補強するが、最終採用判断は ユーザー が保持する。

別 Codex セッションへの peer handoff はユーザーの明示依頼時だけ行う。agmsg は配信モード `off` で手動利用する transport であり、レビュー gate の base pinning / fail-closed aggregation は既存の `$pr-review` / `/pr-review` が担う。

ユーザーが依頼文と結果を編集できる手動の計画レビュー往復を選んだ場合は、skill `plan-review-handoff` の共通手順を使う。

## 用途と起動者

| 用途 | 手段 | 起動者 |
|------|------|--------|
| 実装計画レビュー | `codex exec` via Bash | AI (自動) |
| adversarial コードレビュー | `/codex:adversarial-review` | ユーザー (手動) |
| 調査委譲・長時間タスク・別案の試行 | `/codex:rescue` | ユーザー (手動) |
| バックグラウンド実行管理 | `/codex:status`, `/codex:result` | ユーザー (手動) |
| peer session handoff | agmsg の公式送受信スクリプト | ユーザー (明示依頼) |

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

### agmsg handoff が使える場合

ユーザーが agmsg による依頼を明示し、team と送受信者名を指定し、双方が参加済みの場合だけ利用する。配信モードは `off` を維持し、`bash ~/.agents/skills/agmsg/scripts/send.sh <team> <from> <to> <message>` で送信、`bash ~/.agents/skills/agmsg/scripts/inbox.sh <team> <agent>` で明示された宛先だけを手動受信する。自動参加・監視開始・自動返信は行わない。team は repo ごとに分ける。依頼文は短くし、repo path、branch/base、目的、非対象、検証コマンド、artifact path を含める。長文依頼やレビュー結果は `/tmp/agmsg-handoff-<slug>/request.md` / `result.md` に置き、message では path だけを送る。secret、credential、長大 diff 本文は送らない。

依頼文には「1 回実行して結果を artifact に保存する」を含める。返信の送信もユーザーの明示依頼時だけ行い、自動往復ループを作らない。agmsg が未導入、未 join、または受信側が不明な場合は送受信を止め、不足情報をユーザーに確認する。通常の `codex exec` / `/codex:*` の起動条件は上記のままとし、独立した別セッションへの依頼を標準通信で自動的に代替しない。

### Gotcha: 長い依頼はパイプや既存ファイルから stdin に渡す

`run_in_background: true` で `codex exec "$(cat <<'PROMPT' ... PROMPT)"` のように argv 経由で長い prompt を渡すと、prompt 引数が認識されず `Reading additional input from stdin...` で blocking → 終了する。パイプや既存ファイルから stdin に渡す。呼び出し元が読み取り専用環境では HEREDOC の一時ファイル作成も失敗しうる:

```bash
codex exec --sandbox read-only -C /path/to/repo - < /path/to/request.md
```

## sandbox 注意

`codex exec` / `codex login` は macOS / Linux いずれの sandbox 下でも失敗することがある (macOS: `system-configuration` アクセス制限、Linux: `Read-only file system`)。AI が `dangerouslyDisableSandbox: true` の必要性を判定し Bash 呼び出しに含めるが、最終的な実行は Claude Code の permission prompt 経由で ユーザー が承認する。事前の手動 disable は通常不要。

Linux 側の観測 (2026-09-07、codex-cli 0.153.4 / Claude Code 2.1.263): `dangerouslyDisableSandbox` 未指定・コマンド文字列が `codex --version` のみ、という最小形で `could not create PATH aliases: Read-only file system (os error 30)` が出る (path はメッセージに含まれない)。別途 `~/.codex` は sandbox 内で書き込み不可 (`touch` 失敗、`sandbox.filesystem.allowWrite` に不在)。`codex` は `sandbox.excludedCommands` に入っていない (2026-10-27 に除外を外した。plugin は `node .../codex-companion.mjs` 経由で起動するため `codex *` を除外しても効かない)。したがって `codex` は常に sandbox 内で動き、上記の失敗時は `dangerouslyDisableSandbox` での再実行になる。

なお `Bash(codex exec:*)` は user-global の `permissions.allow` から外してある。narrow allow rule は auto-mode 分類器より先に解決してしまい、起動オプション (`--sandbox` の有無等) が評価されないため。実行時に承認プロンプトが挟まることがあるが想定内。
