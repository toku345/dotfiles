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
- `agentPushNotifEnabled` (公式 doc 未記載) — UI ラベル "Push when Claude decides"、default `true`。実モバイル push は Remote Control 有効時のみ発火 (changelog 2026-04-15)
- `teammateMode` (documented, default `"auto"`) — agent team teammates 表示モード (`auto` / `in-process` / `tmux`)。明示値が default と同一なら settings 記載は redundant
- `claude -p --settings '{"outputStyle":"X"}'` は X が live に未配備/壊れていても rc=0/stderr 空で default style にフォールバックする (claude 2.1.126 で実機確認)。output-style / 配備 asset 依存の automation は file 存在 check ではなく**埋め込み sentinel 文字列の grep 検証**を preflight に置く (例: `/pr-review` skill の `PR_REVIEW_CRITERIA_SHARED_V1` / `PR_REVIEW_SEVERITY_RULES_V1` 検証)
