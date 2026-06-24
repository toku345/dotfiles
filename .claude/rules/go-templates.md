---
paths:
  - "**/*.tmpl"
  - ".chezmoiscripts/**"
---

# Go Template Usage Policy

## Principles

- Go Templates は chezmoi 設定ファイル (`.chezmoi.toml.tmpl`) のみで使う
- shell scripts (`.chezmoiscripts/`) や config ファイルでは環境変数 / runtime 判定を使う

理由: ShellCheck / エディタ拡張との互換性、`.tmpl` 拡張子を避けることでシンタックスハイライトが保たれる。

## CI での chezmoi テンプレート検証

- `promptBoolOnce` 等の init 専用関数は `chezmoi execute-template` 単体では未定義エラーになる。`--init` フラグで有効化する
- テンプレートで chezmoi data を参照する際、CI 等データ未定義環境では `.key` が失敗する。`index . "key"` を使えばキー未定義時に nil を返しエラーにならない

## Environment Variables (chezmoi 自動提供)

`.chezmoiscripts/` 配下のスクリプトに自動付与される: `$CHEZMOI` (=`1`), `$CHEZMOI_OS`, `$CHEZMOI_ARCH`, `$CHEZMOI_SOURCE_DIR`。`scriptEnv` で独自変数を追加可だが、上記の自動提供変数は上書きしないこと（警告が出る）。
