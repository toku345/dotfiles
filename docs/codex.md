# Codex 設定の管理方針

このリポジトリでは `~/.codex` を丸ごと管理しない。

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

## なぜ `config.toml` を直接管理しないか

Codex は `~/.codex/config.toml` に対して、対話の中でローカル状態を書き足すことがある。
代表例:

- `[projects."/absolute/path"]`
- `[mcp_servers.<name>]`
- `[notice.*]`

このファイルを chezmoi 管理下に置くと、`chezmoi apply` のたびにそれらのローカル状態を失いやすい。

## 運用

1. `chezmoi apply` で `~/.codex/config.chezmoi.toml` を配置する
2. `~/.codex/config.toml` が存在しない場合だけ、script が baseline をコピーして初期化する
3. 以後 `~/.codex/config.toml` は live file として残し、Codex が書いた local-only section を保持する
4. baseline を更新したら、`chezmoi apply` 後に `diff -u ~/.codex/config.toml ~/.codex/config.chezmoi.toml` で必要な差分だけ手で取り込む

## local-only とする section

- `[projects."..."]`
- `[mcp_servers.*]`
- `[notice.*]`

必要に応じて、ローカル provider や一時的な実験設定も `~/.codex/config.toml` 側にのみ置く。
