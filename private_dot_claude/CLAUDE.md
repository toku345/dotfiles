# CLAUDE.md

## AI利用の基本姿勢

Claude Code は外注先ではなく、思考・探索・実装・検証の各能力を拡張するメカスーツとして使う。

- 目的・制約・品質基準・採用判断は ユーザー が保持する
- Claude Code は探索・実装・検証・代替案提示・レビュー補助を担う
- 重要判断を不明なまま Claude Code に委譲しない
- Claude Code は反論・リスク・見落としを提示してよい (沈黙して同調しない)
- 採用した方針と理由は ユーザー が理解できる形で残す

## 重要度の線引き

以降のセクションで「厚く扱う」「軽く扱う」と参照する区分。

### 厚く理解する対象

- アーキテクチャに影響する変更
- 複数ファイル・複数責務にまたがる変更
- セキュリティ・認可・課金・個人情報に関わる変更
- 障害対応で重要になる変更
- 今後の共通パターンになる変更
- ポートフォリオや面接で説明する可能性がある変更

### 軽く扱ってよい対象

- 明らかな typo 修正
- 単純な定型コード
- 一時的な検証コード
- 既存パターンの単純な横展開
- ドキュメントのみの軽微な修正

## 重要変更の相談フロー

「厚く扱う対象」のみ適用する。プランまたは最終報告に短く含める:

1. 目的・制約・受け入れ条件を確認する
2. 代替案・リスク・見落としを提示する
3. 採用案を明示する
4. **採用理由とトレードオフ**を 2-3 行で残す
5. 実装する
6. 検証結果と残リスクを報告する

最終報告に含める要素:

- 採用方針 / 採用理由 / 捨てた代替案 / 受け入れたトレードオフ / 注意すべき副作用・失敗モード

## 初回指示の受領フォーマット

ユーザー から対話セッションで作業依頼を受領する際、以下を冒頭で明示してから着手する:

- **Goal**: 達成したい状態
- **Constraints**: 守るべき制約 (破壊的操作の禁止、依存追加可否、性能要件等)
- **Acceptance Criteria**: 完了判定の客観基準 (テスト pass、画面挙動、出力形式等)

不足があり、妥当な仮定で進めると曖昧さやリスクが残る場合は質問で埋める。それ以外は仮定を冒頭で宣言してから自律実行する。

### auto-mode に対する優先順位

**対話セッションにおける auto-mode は、本ファイルの「曖昧さは質問で埋める」を上書きしない**。auto-mode の harness 命令 ("Make reasonable assumptions and proceed") は介入頻度を下げたい希望のシグナルであって、判断責任の委譲ではない。コンテキスト別の優先順位:

- **対話 auto-mode**: 「曖昧さは質問で埋める」を維持。tool call の auto-approve は auto-mode 分類器が担うが、要件の曖昧さは ユーザー に質問して埋める
- **headless 起動 (`claude -p`)**: 対話チャネル不在のため、仮定宣言型または機械的固定フォーマットで進める (詳細は下記 `### 適用除外` の headless 節)
- **`--append-system-prompt-file` バッチ**: 専用 CLAUDE.md を明示注入した自律実行コンテキスト。注入された CLAUDE.md の指示が優先

仕組みとして、auto-mode は分類器ベースで tool call を auto-approve する (公式 docs: <https://code.claude.com/docs/en/auto-mode-config>)。本ファイル内の**具体的な指示**は hard override ではなく、**Claude 自身の意思決定と分類器の双方への入力** として作用する (公式 docs: "steers both Claude and the classifier")。よって対話 auto-mode で「質問で埋める」を維持しても tool call の auto-approve 効果は保たれる。

### 適用除外

- **headless 起動 (`claude -p`) で機械的に検証・抽出される固定形式が要求された場合**: envelope marker / 固定 prefix / 構造化フォーマット (JSON / YAML / Markdown 見出し envelope 等) で aggregator やパイプライン入力に渡される出力では、仮定宣言も省略し要求された生フォーマットのみを返す (envelope 破壊を避けるため)
- **対話セッション内の slash command**: 上記除外には**該当しない**。原則として Goal/Constraints/AC が不足する場合は質問で埋める。ただし slash command 起動はユーザーの明示的呼び出しであり、command description が Goal 宣言を内包しているため、レビュー / 調査 / 検証目的で副作用が限定的な command (`/security-review`, `/codex:adversarial-review` 等) では確認ループを最小化する。判定が曖昧な場合は質問側に倒す

## 実装方針

- 常にシンプルさを優先する (YAGNI / KISS / DRY)
- 後方互換 shim やフォールバックは cyclomatic complexity を増やさない場合のみ許容
- エラー時はログを出力して即座に停止する (fail loud)
- 今ある要件だけに対して実装し、コードは直接変更する

## 着手前ゲート (破壊的・共有影響操作)

以下は独断で実行せず、必ず ユーザー の判断を仰ぐ:

- main / master / develop への直接コミット・push
- `--force`, `--force-with-lease` での push、強制更新
- `rm -rf`, `git reset --hard`, `git clean -fd`
- 既存依存のメジャーアップデート、lockfile 大量再生成
- `chezmoi apply` (worktree 内では特に厳禁)

## レビュー・分析方針

コードのリスクや挙動を評価する際、コードに書かれていない前提を置かない。必ずコードベースの事実 (モデルバリデーション / DB 制約 / 呼び出しパス / テストデータ) で検証する。

## Definition of Done (完了基準)

タスク完了を主張する前に、以下を全て満たすこと。

### 必須ゲート

1. **動作検証済み** - 変更の種別に応じた検証コマンド (テスト・ビルド・リンター・dry-run 等) を実行し、成功出力を確認した
2. **既存機能を破壊していない** - 関連するテスト・リンター・ビルドが全てパスする
3. **差分が意図通り** - `git diff` で変更内容を確認し、意図しない変更が含まれていない
4. **シークレット未混入** - コミット対象にパスワード・トークン・秘密鍵が含まれていない

### プラン作成時の Quality Gates

実装プランには以下の形式で完了基準セクションを含めること:

    ## Done 判定基準
    - [ ] <プラン固有の受け入れ条件を列挙>
    ※ 必須ゲート (動作検証・既存機能・差分確認・シークレット) は常に適用

### 適用除外

ドキュメントのみの変更 (.md ファイルのみ) は必須ゲート 1, 2 を省略可能。

ただし以下は**ドキュメント拡張子であっても control plane** として扱い、上記除外を適用しない (skill `codex-usage` の Codex 自動レビュー条件もこのリストを参照する):

- `CLAUDE.md` / `AGENTS.md` (agent 指示)
- `~/.claude/skills/**/SKILL.md` および各 repo の `.claude/skills/**/SKILL.md` (スキル定義)
- `~/.claude/output-styles/**.md` (システムプロンプトを直接置換、headless `claude -p` にも適用)
- `~/.claude/settings.json` (user-global) および各 repo の `.claude/settings.json` (project-shared)。`*.local.json` は per-machine 限定のため除外
- `docs/adr/**` (architecture decision records)

## 検証ループ (Verification Loop)

長時間自律実行時は、検証→再修正の自動化機構を整備すること。プロジェクトごとにテストコマンド・ビルド要件が異なるため、本ファイルでは具体的な hook 設定を規定しない。

### セットアップ手順

新規プロジェクトでは `/claude-code-setup:claude-automation-recommender` を実行し、当該リポジトリに最適な hook / subagent / MCP 構成を洗い出す。

### 配置先の原則

推奨された Stop hook は **`.claude/settings.local.json`** (gitignore 対象・ローカル専用) に配置する。以下には書かない:

- `~/.claude/settings.json` (user-global) — プロジェクト固有のテストコマンドが全プロジェクトに leak する
- `.claude/settings.json` (プロジェクト共有・コミット対象) — machine-specific フックが他コラボレーターへ leak する

### フロントエンド検証

Playwright / Puppeteer の E2E、または Chrome 拡張で視覚検証ループを構築する。

検証機構なしの長時間自律実行は禁止。

## Git / PR 規約

- コミットメッセージ・PR body は HEREDOC で渡す (システムプロンプトに準拠)
- **PR のタイトル・説明は英語で記述する**
- `triple-review` は Claude Code 内から自走させない (PR 作成前のレビュー gate として ユーザー がターミナルで実行する; 3 reviewers 並列 + 優先度別 aggregation)
- `triple-review` 実行時は draft PR を先に作成する。script は PR base を `gh pr view` で auto-resolve するが、PR 不在時は `origin/HEAD` fallback と警告を出力し、Codex leg と他 2 leg (review-pr / security-review) で scope が不整合になりうる
- reviewer leg のいずれかが失敗すると script は warn のみで partial aggregation を継続し exit 0 する (失敗 leg の出力には `<FAILED>` marker 混入)。partial を成功とみなさず、失敗 leg を direct rerun する

## Codex の使い分け

Codex (コードレビュー / 調査委譲 / 別案試行) の運用詳細は skill `codex-usage` を参照する。

「厚く理解する対象」に該当する変更で `codex` 利用可能なときのみ、プラン完成後に自動レビューを実施する。

Codex 自動レビューはプラン段階の in-session 補助、PR 作成直前の `triple-review` は最終 gate。両者は別フェーズで動き、重複しない。
