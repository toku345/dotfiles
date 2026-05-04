# CLAUDE.md

## 初回指示の受領フォーマット

No.13 から対話セッションで作業依頼を受領する際、以下を冒頭で明示してから着手する:

- **Goal**: 達成したい状態
- **Constraints**: 守るべき制約（破壊的操作の禁止、依存追加可否、性能要件等）
- **Acceptance Criteria**: 完了判定の客観基準（テスト pass、画面挙動、出力形式等）

不足があり、かつ妥当な仮定で進めると曖昧さやリスクが残る場合のみ質問で埋める。
それ以外は仮定を冒頭で宣言してから自律実行する。

### 適用除外

- **auto-mode active 時**: system 注入の "Make reasonable assumptions and proceed on low-risk work" を優先し、仮定宣言型で進める
- **対話セッション内の slash command**: 上記除外には**該当しない**。対話チャネルがあるため、mutating 操作で Goal/Constraints/AC が不足する場合は通常通り質問で埋める

## 実装方針

常にシンプルさを優先する。
YAGNI, KISS, DRY。
後方互換shimやフォールバックはcyclomatic complexityを増やさない場合のみ許容。
エラー時はログを出力して即座に停止する（fail loud）。
今ある要件だけに対して実装し、コードは直接変更する。

## 着手前ゲート（破壊的・共有影響操作）

以下は独断で実行せず、必ず No.13 の判断を仰ぐ:

- main / master / develop への直接コミット・push
- `--force`, `--force-with-lease` での push、強制更新
- `rm -rf`, `git reset --hard`, `git clean -fd`
- 既存依存のメジャーアップデート、lockfile 大量再生成
- `chezmoi apply`（worktree 内では特に厳禁）

## レビュー・分析方針

コードのリスクや挙動を評価する際、コードに書かれていない前提を置かない。
必ずコードベースの事実（モデルバリデーション、DB制約、呼び出しパス、テストデータ）で検証する。

## Definition of Done（完了基準）

タスク完了を主張する前に、以下を全て満たすこと。

### 必須ゲート

1. **動作検証済み** - 変更の種別に応じた検証コマンド（テスト・ビルド・リンター・dry-run 等）を実行し、成功出力を確認した
2. **既存機能を破壊していない** - 関連するテスト・リンター・ビルドが全てパスする
3. **差分が意図通り** - `git diff` で変更内容を確認し、意図しない変更が含まれていない
4. **シークレット未混入** - コミット対象にパスワード・トークン・秘密鍵が含まれていない

### プラン作成時の Quality Gates

実装プランには以下の形式で完了基準セクションを含めること:

    ## Done 判定基準
    - [ ] <プラン固有の受け入れ条件を列挙>
    ※ 必須ゲート（動作検証・既存機能・差分確認・シークレット）は常に適用

### 適用除外

ドキュメントのみの変更（.md ファイルのみ）は必須ゲート 1, 2 を省略可能。

## 検証ループ（Verification Loop）

長時間自律実行時は、検証→再修正の自動化機構を整備すること。
プロジェクトごとにテストコマンド・ビルド要件が異なるため、本ファイルでは具体的な hook 設定を規定しない。

### セットアップ手順

新規プロジェクトでは `/claude-code-setup:claude-automation-recommender` を実行し、当該リポジトリに最適な hook / subagent / MCP 構成を洗い出す。

### 配置先の原則

推奨された Stop hook は **`.claude/settings.local.json`**（gitignore 対象・ローカル専用）に配置する。
以下には書かない:

- `~/.claude/settings.json`（user-global）— プロジェクト固有のテストコマンドが全プロジェクトに leak する
- `.claude/settings.json`（プロジェクト共有・コミット対象）— machine-specific フックが他コラボレーターへ leak する

### フロントエンド検証

Playwright / Puppeteer の E2E、または Chrome 拡張で視覚検証ループを構築する。

検証機構なしの長時間自律実行は禁止。

## Git / PR 規約

- コミットメッセージ・PR body は HEREDOC で渡す（システムプロンプトに準拠）
- **PR のタイトル・説明は英語で記述する**

## Codex の使い分け

| 用途 | 手段 | 起動者 |
|------|------|--------|
| 実装計画レビュー | `codex exec` via Bash | AI（自動） |
| adversarial コードレビュー | `/codex:adversarial-review` | ユーザー（手動） |
| 調査委譲・長時間タスク・別案の試行 | `/codex:rescue` | ユーザー（手動） |
| バックグラウンド実行管理 | `/codex:status`, `/codex:result` | ユーザー（手動） |

PR 前のレビュー順: `/pr-review-toolkit:review-pr` → `/security-review` → `/codex:adversarial-review`

### 実装計画立案時の自動 Codex レビュー

`codex` 利用可能で、かつ以下のいずれかに該当する時のみ実施する:

- 複数ファイルにまたがる変更
- アーキテクチャに影響する設計判断
- 既存の振る舞いを変更するリファクタリング

単一ファイルの軽微な修正・ドキュメントのみ・設定値変更には**適用しない**。

実行: プラン完成後 `codex exec "...プランレビュー...$(cat <plan>)"` でレビュー依頼。
指摘があれば反映後 `codex exec resume --last "..."` で再レビュー。
致命的な指摘が消えるまで反復。
