---
paths:
  - "private_dot_claude/**"
---

# Claude Code Configuration Quirks

- `outputStyle` 切替は `/config` メニュー経由のみ (公式スラッシュコマンド・CLI フラグ未提供)、反映は次の新規セッションから
- `outputStyle` はシステムプロンプトを直接置換し headless `claude -p` にも適用 (Agent tool 経由の subagents には伝播しない)
- precedence: project-local (`<repo>/.claude/settings.local.json`) > user-global (`~/.claude/settings.json`)
- 本リポジトリは JUIZ persona を user-global default に設定。詳細: `docs/adr/0015-multi-persona-output-styles.md`
- `verbose: true` (公式 doc 未記載だが実在) — UI ラベル "Verbose output"、default `true`、turn-by-turn logging を制御 (`--verbose` CLI flag の persistent 版)
- `viewMode` (`"default"` / `"verbose"` / `"focus"`、default `"default"`) — startup transcript view を制御。`verbose` とは別レイヤーで両者独立。verbose 表示にしたければ明示設定必要。<https://code.claude.com/docs/en/settings>
- `/config` UI 表示値は **effective default**（stored ≠ displayed）。settings.json に該当キーが無くても UI は default を表示する。**閲覧のみでは settings.json は書き換わらず**、UI で toggle した時のみ書き込まれる (2026-05-02 実機検証)
- `/config` toggle 後の運用: `chezmoi diff` で新規キー確認 → 公式 doc 照会 → default / undocumented キーは `chezmoi apply` で live をクリーンアップ (source 主導削除)、必要なキーのみ `chezmoi re-add` で source に取り込み
- `agentPushNotifEnabled` — UI ラベル "Push when Claude decides"。**default 値の記録が矛盾している**: 本 repo の実機検証は `true`、公式 docs は 2026-08-17 時点で `false` と記載 (<https://code.claude.com/docs/en/settings>、要約モデル経由の取得で**未再検証**)。現行設定 `true` はどちらが正でも無害 (docs が正なら非既定として明示が正しく、実測が正なら冗長なだけ) のため変更しない。実モバイル push は Remote Control 有効時のみ発火 (changelog 2026-04-15)
- `teammateMode` (documented, default `"auto"`) — agent team teammates 表示モード (`auto` / `in-process` / `tmux`)。明示値が default と同一なら settings 記載は redundant
- `claude -p --settings '{"outputStyle":"X"}'` は X が live に未配備/壊れていても rc=0/stderr 空で default style にフォールバックする (claude 2.1.126 で実機確認)。output-style / 配備 asset 依存の automation は file 存在 check ではなく**埋め込み sentinel 文字列の grep 検証**を preflight に置く (例: `/pr-review` skill の `PR_REVIEW_CRITERIA_SHARED_V1` / `PR_REVIEW_SEVERITY_RULES_V1` 検証)

## auto-mode 分類器 (v2.1.233 時点)

- **`permissions.ask` の content-scoped rule は分類器より前に評価され、auto mode でも必ずプロンプトする** (公式 docs)。CLAUDE.md の「着手前ゲート」は steering であり、実効的な gate はこちら
- **v2.1.211 で Default / protected branches の既定が撤廃**され、working repo の任意ブランチ (main 含む) への push が既定許可になった。現在 main への直接 push を止めているのは `permissions.ask` の `Bash(git push:*)` **のみ**で、この 1 エントリは load-bearing。削除・緩和する前に対象リポジトリの server-side 保護 (`pull_request` + `non_fast_forward`) を確認する
- **分類器は Claude と同じ CLAUDE.md を読む** — 制約記述の削除は分類器も緩める。詳細: `docs/adr/0036-user-global-claude-md-placement-policy.md`
- soft_deny に `Self-Modification` (`.claude/settings*.json` / `CLAUDE.md` / `.claude/rules/` 等への guard 弱体化編集) と `Instruction Poisoning` (読み戻される instruction ファイルへの permission grant 内容の書き込み) がある。これらのファイルを編集する作業は分類器に止められうる。**ブロックされたら回避せず**ユーザーの明示承認を得る (`Auto-Mode Bypass` ルールが回避を禁じている)
- `autoMode` は `~/.claude/settings.json` / `--settings` / managed settings のみから読まれる。`~/.claude/settings.local.json` は**存在しない概念**、project の `.claude/settings.json` / `.claude/settings.local.json` は**読まれない** (v2.1.207 以降)
- 実効ルールの確認: `claude auto-mode config` / `claude auto-mode defaults --label '<ルール名>'`。本 repo は custom rule を持たない方針 (ADR 0014 / 0036)
