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

軽く扱ってよい対象 (typo / 単純な横展開 / ドキュメントのみ / 設定値変更) には **適用しない**。

### 実行手順

1. プラン完成後、初回レビュー依頼:

   ```bash
   codex exec "...プランレビュー...$(cat <plan>)"
   ```

2. 指摘があれば反映後、再レビュー:

   ```bash
   codex exec resume --last "..."
   ```

3. 致命的な指摘が消えるまで反復する。

## sandbox 注意

`codex exec` / `codex login` は macOS sandbox 下で `system-configuration` アクセス制限により失敗することがある。AI が `dangerouslyDisableSandbox: true` の必要性を判定し Bash 呼び出しに含めるが、最終的な実行は Claude Code の permission prompt 経由で ユーザー が承認する。事前の手動 disable は通常不要。
