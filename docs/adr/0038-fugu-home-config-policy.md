# ADR 0038: 分離した Fugu home の base config を per-key policy で管理する

## Status

Accepted (2026-09-26).

## Context

[ADR 0037](0037-codex-config-per-key-policy.md) は `~/.codex/config.toml` を chezmoi の `modify_` target にし、`scripts/codex-config/merge.py` で per-key の pin / seed を適用する。一方、[docs/codex.md](../codex.md) の分離手順で作る `~/.codex-fugu` は、専用 CLI の分離を優先して丸ごと chezmoi 非管理としてきた。

分離した Fugu home には 2 つの config 層がある。base layer の `~/.codex-fugu/config.toml` と、公式インストーラーが配置して丸ごと上書きする bundle profile `~/.codex-fugu/fugu.config.toml`（ランチャーは `codex -p fugu` で読み込む）である。恒久修正を置けるのは、installer が一部のマーカーブロックしか書き換えない base layer だけ。

2026-09-22 の実測で、Plan mode が次の理由で壊れることを確認した。Fugu モデルの catalog は `high` / `xhigh`（`fugu-ultra-v1.1` のみ `max`）しか宣言しない一方、Codex の Plan mode 組み込み既定は `medium` である。base layer に `plan_mode_reasoning_effort` がないため `medium` が送られ、Sakana API が `Invalid 'reasoning.effort'` で拒否する。マシンローカルに 1 行を手で置く回避策で Plan mode は復旧し、rollout には `"reasoning_effort":"xhigh"` が記録された。

## Decision

`~/.codex-fugu/config.toml` を chezmoi の `modify_` target にし、通常版と同じ `scripts/codex-config/merge.py` で per-key policy を適用する。Fugu 側のポリシーは `scripts/codex-config/policy-fugu.toml` に分離し、`merge.py` の `--policy <name>`（`policy*.toml` のファイル名のみ許可し、source directory 直下で解決する）で選択する。通常版の sandbox / features / tui の pin は Fugu home へ持ち込まない。

宣言するのは `plan_mode_reasoning_effort = "xhigh"` の **pin** だけとする。seed ではないのは、Plan mode を壊す値が live に保存されていても `apply` ごとに戻す必要があるため。`[seed]` は空にし、`config_policy.load_policy` は `[pin]` / `[seed]` の両テーブルを要求しつつ、片方の空を許容して全体で 1 つ以上の宣言を必須にする。

配布はマシン単位の opt-in にする。`.chezmoi.toml.tmpl` の `[data]` に `codexFugu` を追加し、`.chezmoiignore` が `{{ if not (index . "codexFugu") }}` で `.codex-fugu` と `.codex-fugu/**` を除外する。`~/.codex-fugu` を持たない machine に空の target を作らないため。既に init 済みの machine では `chezmoi init` を実行して `codexFugu` のプロンプトに答える（実測: data への手動追記だけでは config template 変更の警告が残り、`promptBoolOnce` は TTY を要求するため `--promptBool` では埋まらない。非対話では data 追記後に `chezmoi init` を実行する）。

`merge.py` は未設定の root キーをファイル先頭に前置する。installer のマーカーブロックが最初のテーブルを含むため、TOML Kit の既定配置（最初のテーブル直前）では新しい root キーがブロックの内側に入り、既存の「installer ブロック不変」検証で停止する。前置はブロックを触らず、root キーが常に top-level に残る。

## Consequences

### Positive

- Plan mode が `medium` を送ることが構造的に起きなくなり、Fugu home でも Plan mode が動く。手動の 1 行回避策は役目を終える。
- 通常版と Fugu でポリシーが分離され、Fugu home へ sandbox / features / tui の pin が漏れない。
- Fugu を使わない machine では source 一式が ignore され、`~/.codex-fugu` を作らない。
- installer が書き換えるマーカーブロックと Codex が書く runtime state（`[projects.*]` / `[hooks.state]`）は引き続き保持される。

### Negative

- Fugu home も `sh scripts/codex-config/setup.sh` の venv に依存する target になった。venv 未準備では `diff` / `apply` が fail-closed する。
- pin なので、Fugu home の Plan mode effort を変えたい場合は `policy-fugu.toml` を編集する必要がある。TUI 等で保存した値は次の `apply` で戻る。
- `merge.py` の root キー挿入位置が変わった。新しい root キーはファイル先頭に入るため、通常版の config では既存コメントより前に置かれる場合がある（値・free キー・ブロックの保持は検証済み）。
- `codexFugu = true` を有効にした machine に `~/.codex-fugu` が無い場合、chezmoi は pin 1 行の skeleton を作る。有効化は専用 HOME を持つ machine に限る。

### Alternatives

- 通常版の `policy.toml` を Fugu home にも適用する案は、`model = "gpt-6-astra"` seed と sandbox / features / tui の pin を Fugu base layer へ入れるため不採用。
- マシンローカルの 1 行を維持する案は、installer の再実行や他 machine へ伝播せず、Plan mode 破損が再発し得るため不採用。
- `~/.codex-fugu/fugu.config.toml` を編集する案は、installer が丸ごと上書きするため不採用。
- upstream（SakanaAI/fugu）の bundle 側へ 1 行を提案するのは任意であり、dotfiles 側の実装をブロックしない。
