# ADR 0037: Codex config の per-key pin/seed 管理

## Status

Accepted (2026-09-23). Supersedes [ADR 0024](0024-codex-baseline-hash-state.md).

## Context

ADR 0024 は `~/.codex/config.toml` を chezmoi の所有物にせず、baseline `config.chezmoi.toml` を配置して hash gate で drift を検出し、operator が live へ手動 merge + ACK する設計だった。運用の結果、次の問題が確定した。

- baseline が「初期値の供給源 (seed)」と「唯一の正」を兼ね、Codex が live に書き足す local-only section との差分 merge が毎回必要になった。2026-09 時点の実測で baseline 48 行に対し live は 266 行、`model` / `model_reasoning_effort` / `features` / `plugins` / `sandbox_workspace_write.writable_roots` / `tui` が乖離していた。
- 無関係な dotfile を `chezmoi apply` したいだけでも、baseline hash の変化だけで exit 1 で停止した。
- merge は AI エージェントによる live file の書き換えを前提にしており、再現性が低かった。

同時に Codex CLI 0.154.0 の実測で、設定は packaged defaults / system / user config / profile file / project config / managed requirements の層に分かれ、**user config と profile file のどちらにも Codex 自身が書き込む**ことが分かった（隔離した Fugu home では profile file に `[projects.*]` と `[hooks.state]` が現れた）。「Codex が書くファイルを chezmoi が所有しない」原則は維持しつつ、キー単位で所有権を分ける必要がある。

## Decision

`~/.codex/config.toml` を chezmoi の `modify_` target にし、`private_dot_codex/modify_private_config.toml`（POSIX sh + awk）が live file を stdin で受け取り、ポリシー適用後の内容を stdout に出す。chezmoi は live file を所有せず、script が計算した内容だけを書き戻す。script の stderr は警告専用で、`apply` と `diff` の両方にそのまま出る。

ポリシーは script 内の 1 つの表に集約し、3 種類に分ける。

- **pin**: `chezmoi apply` ごとに再適用する (`sandbox_mode` / `approval_policy` / `approvals_reviewer` / `sandbox_workspace_write.network_access` / 宣言済み `features.*` / `features.context_management` / `tui.status_line*`)
- **seed**: キーが存在しないときだけ投入する (`model` / `model_reasoning_effort` / `plan_mode_reasoning_effort` / `personality`)。live の値が宣言値と違うときは stderr に警告し、live を保持する
- **free**: 一切触らない (`plugins` / `mcp_servers` / `projects` / `notice` / `hooks.state` / `notify` / `service_tier` / `sandbox_workspace_write.writable_roots`)

値の比較は空白・括弧・引用符・末尾カンマを正規化して行う。Codex が配列を複数行に整形し直しても drift とみなさないため。

`requirements.toml` は採用しない。0.154.0 の requirements schema は allow-list と feature requirement のみで reasoning effort を表現できず、読込パスも `/etc/codex/requirements.toml` と managed-requirements に限られ、ユーザー層のパスは確認できなかった。sudo を `chezmoi apply` の経路へ持ち込まないことを優先する。

hash gate は廃止する。pin は無条件に再適用され、seed の乖離は警告だけで、どちらも手動 merge を要求しないため gate に意味がない。`~/.codex/.baseline-hash` は移行時に削除する。

## Consequences

### Positive

- ポリシー変更が全端末へ自動伝播し、手動 merge と ACK が不要になった。
- Codex / installer が書く section (`projects` / `mcp_servers` / `notice` / `hooks.state` / `plugins` / `writable_roots`) は apply で保持される。
- 方針が 1 つの表に集約され、pin/seed/free の判定をレビューしやすくなった。
- `chezmoi apply` が無関係な config drift で停止しなくなった。

### Negative

- `~/.codex/config.toml` が chezmoi の `diff` / `status` に出る target になった（内容は script の計算結果として表示される）。
- pin は TUI での変更を打ち消す。日常的に切り替える値は seed に分類する必要がある。
- script は TOML を構造としてではなく行レベルで扱う。複数行文字列やインラインテーブルをポリシーへ追加する場合は script の拡張が必要。
