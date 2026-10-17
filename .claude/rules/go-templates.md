---
paths:
  - "**/*.tmpl"
  - ".chezmoiignore"
  - ".chezmoiscripts/**"
---

# Go Template Usage Policy

## Principles

- Go Templates は、生成時の環境差分や正本共有など、生成時の処理が必要な用途に使う。使用範囲は `.chezmoi.toml.tmpl` に限定しない
- 既存の用途には、`.chezmoi.toml.tmpl` の初期設定、SSH / Starship の OS・機器別設定、`.chezmoiignore` 等の配置条件、共有レビュー資産の `include` がある。これは例示であり、許可するファイルの限定列挙ではない
- 通常の shell scripts (`.chezmoiscripts/` 等) では環境変数 / runtime 判定を優先する。ShellCheck / エディタ拡張との互換性やシンタックスハイライトを保つため、不要な `.tmpl` 化を避ける
- 正本を共有する薄い `include` wrapper（Markdown / JSON / Python 等）は runtime 判定とは別の用途である。実装・ルールは正本で維持し、wrapper に複製しない

template の評価前確認や worktree の source 選択、live apply の承認・検証は [AGENTS.md の Chezmoi Operations](../../AGENTS.md#chezmoi-operations) に従う。scripts の除外だけでは template や modifier の実行を防げない。

## CI での chezmoi テンプレート検証

- `promptBoolOnce` 等の init 専用関数は `chezmoi execute-template` 単体では未定義エラーになる。`--init` フラグで有効化する
- テンプレートで chezmoi data を参照する際、CI 等データ未定義環境では `.key` が失敗する。`index . "key"` を使えばキー未定義時に nil を返しエラーにならない

## Environment Variables (chezmoi 自動提供)

`.chezmoiscripts/` 配下のスクリプトに自動付与される: `$CHEZMOI` (=`1`), `$CHEZMOI_OS`, `$CHEZMOI_ARCH`, `$CHEZMOI_SOURCE_DIR`。`scriptEnv` で独自変数を追加可だが、上記の自動提供変数は上書きしないこと（警告が出る）。
