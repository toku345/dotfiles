# Codex 設定の管理方針

このリポジトリでは `~/.codex` を丸ごと管理しない。

設計判断 (3-file 構成 / hash gate / migration fail-closed) の詳細は [ADR 0024](adr/0024-codex-baseline-hash-state.md) を参照。

## 管理するもの

- `private_dot_codex/AGENTS.md` -> `~/.codex/AGENTS.md`
- `private_dot_codex/private_config.chezmoi.toml` -> `~/.codex/config.chezmoi.toml`
- `.chezmoiscripts/run_after_check-codex-config.sh`

## 管理しないもの

- `~/.codex/auth.json`
- `~/.codex/history.jsonl`
- `~/.codex/sessions/`
- `~/.codex/state_*.sqlite`
- `~/.codex/logs_*.sqlite*`
- `~/.codex/cache/`
- `~/.codex/rules/default.rules`
- `~/.codex/.baseline-hash` (chezmoi script が生成する hash state)

## 運用

1. `chezmoi apply` で `~/.codex/config.chezmoi.toml` を配置する
2. `~/.codex/config.toml` が存在しない場合だけ、script が baseline をコピーして初期化する
3. 以後 `~/.codex/config.toml` は live file として残し、Codex が書いた local-only section を保持する
4. baseline を更新したら、`chezmoi apply` が baseline の hash 変化を検出して exit 1 で停止する。`diff -u ~/.codex/config.toml ~/.codex/config.chezmoi.toml` で baseline 更新分を確認し、local-only section を保ったまま live に取り込む。merge 後、新 baseline を ACK するため `hash=$(sha256sum ~/.codex/config.chezmoi.toml 2>/dev/null || shasum -a 256 ~/.codex/config.chezmoi.toml) && printf '%s\n' "${hash%% *}" > ~/.codex/.baseline-hash && chmod 600 ~/.codex/.baseline-hash` を実行し、再 `chezmoi apply` する。無関係な dotfile を急ぎ apply したい場合は `chezmoi apply <target>` で個別指定すればこの script は trigger されない

## local-only とする section

- `[projects."..."]`
- `[mcp_servers.*]`
- `[notice.*]`

必要に応じて、ローカル provider や一時的な実験設定も `~/.codex/config.toml` 側にのみ置く。

## status line

Codex CLI の TUI footer は baseline で最小限の常時表示にする。

- `model-with-reasoning`
- `current-dir`
- `git-branch`
- `context-remaining`
- `five-hour-limit`
- `codex-version`

`used-tokens` は長時間セッションの診断には有用だが、常時表示ではノイズになりやすいため baseline には入れない。必要な時は `/status` または `/statusline` で確認する。

## review profile

`model_reasoning_effort = "xhigh"` は監査には有用だが、通常の反復レビューでは過剰になりやすい。baseline では `high` を default とし、用途別 profile で明示的に切り替える。

- `review`: 通常レビュー・dogfood iteration 用
- `review_deep`: 複雑な PR や main pre-merge review 用
- `review_audit`: security / release / cutover audit 用

`xhigh` の出力は自動修正キューではなく triage input として扱う。反復修正ループは通常 `medium` か `high` で 1-2 周に抑える。

## commit attribution

Codex CLI 0.131 系で `codex_git_commit` feature flag と `commit_attribution` config は削除された。baseline ではこれらの削除済み config は使わず、個人 preference として `~/.codex/AGENTS.md` に Co-authored-by trailer 指示を置く。

## 通知

macOS の desktop notification は今後の検討事項。`notify = [...]` は helper の存在や OS 差分に依存するため、baseline へ固定値として入れる前に template / opt-in / availability check の方針を決める。
