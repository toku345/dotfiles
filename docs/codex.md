# Codex 設定の管理方針

このリポジトリでは `~/.codex` を丸ごと管理しない。

## 管理するもの

- `private_dot_codex/AGENTS.md` -> `~/.codex/AGENTS.md`
- `private_dot_codex/private_config.chezmoi.toml` -> `~/.codex/config.chezmoi.toml`
- `.chezmoiscripts/run_after_check-codex-config.sh`

`config.chezmoi.toml` は新規環境向けの bootstrap baseline として使う。
管理対象は安全方針と明確に opt-in した機能に絞る。

## 管理しないもの (files)

- `~/.codex/auth.json`
- `~/.codex/history.jsonl`
- `~/.codex/sessions/`
- `~/.codex/state_*.sqlite`
- `~/.codex/logs_*.sqlite*`
- `~/.codex/cache/`
- `~/.codex/rules/default.rules`

`config.toml` 内の local-only な TOML keys / sections は「local-only とする section」を参照する。

## マシン固有の上書き

`chezmoi apply` は `~/.codex/AGENTS.md` を repo の内容で全置換する。
マシン固有の guidance や一時的な調整は、Codex 公式の `~/.codex/AGENTS.override.md` (untracked) を使う。
override が存在する場合 Codex は `AGENTS.md` ではなく override を読む。
参照: <https://developers.openai.com/codex/guides/agents-md>

## なぜ `config.toml` を直接管理しないか

Codex は `~/.codex/config.toml` に対して、対話の中でローカル状態を書き足すことがある。
代表例:

- `[projects."/absolute/path"]`
- `[mcp_servers.<name>]`
- `[notice.*]`
- `[tui.*]`

このファイルを chezmoi 管理下に置くと、`chezmoi apply` のたびにそれらのローカル状態を失いやすい。
モデル指定も Codex の更新や用途に合わせて頻繁に変えるため、live file 側に置く。

## 運用

1. `chezmoi apply` で `~/.codex/config.chezmoi.toml` を配置する
2. `~/.codex/config.toml` が存在しない場合だけ、script が baseline をコピーして初期化する
3. 以後 `~/.codex/config.toml` は live file として残し、Codex が書いた local-only section を保持する
4. モデルや reasoning effort は `~/.codex/config.toml` 側で直接調整する
5. baseline を更新したら、必要なときだけ `diff -u ~/.codex/config.toml ~/.codex/config.chezmoi.toml` で差分を確認して手で取り込む

## live file の変更を共通化する流れ

`~/.codex/config.toml` をそのまま `chezmoi add` しない。
このファイルにはローカル状態や絶対パスが混ざるため、共通化したい設定だけを選んで baseline に昇格する。

1. 変更元ホストで差分を見る:
   `diff -u ~/.codex/config.chezmoi.toml ~/.codex/config.toml`
2. 共通化する項目だけを選ぶ
3. chezmoi source 側の `private_dot_codex/private_config.chezmoi.toml` に手で反映する
4. `chezmoi apply` で `~/.codex/config.chezmoi.toml` を更新する
5. 他ホストでは repository を更新して `chezmoi apply` を実行する
6. 既存の `~/.codex/config.toml` には自動 merge しないため、必要な項目だけ手で取り込む

新規ホストでは、`~/.codex/config.toml` が存在しなければ baseline から初期化される。

## local-only とする section

- `model`
- `model_reasoning_effort`
- `plan_mode_reasoning_effort`
- `[projects."..."]`
- `[mcp_servers.*]`
- `[notice.*]`
- `[tui.*]`

必要に応じて、ローカル provider や一時的な実験設定も `~/.codex/config.toml` 側にのみ置く。
