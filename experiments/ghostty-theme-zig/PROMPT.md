# Ghostty theme selector: Zig port

現行 Bash 版を参照して、Ghostty のテーマ選択・適用ツールを Zig 0.16.0 で実装してください。計画だけで終了せず、ビルドと自動検証が通る試作版まで完成させてください。

## 作業範囲

- 変更は `experiments/ghostty-theme-zig/` 内に限定してください。既存の管理対象スクリプト・設定・テストは読み取り専用の参照資料です。
- リポジトリのルートを基準として、以下を読んでください。
  - `dot_local/bin/executable_ghostty-theme`
  - `dot_local/bin/executable_ghostty-theme-preview`
  - `tests/bats/test_ghostty_theme.bats`
  - `tests/bats/test_helper.bash` と `tests/bats/test_helper_bash5.bash`
  - `tests/bats/bin/ghostty` と `tests/bats/bin/fzf`
  - `tests/bats/fixtures/themes/` と `tests/bats/fixtures/user_themes/`
  - `tests/bats/snapshots/ghostty-theme/`
- `chezmoi apply`、実際のユーザー設定の変更、インストール、push は行わないでください。コミットは不要です。
- 開発中のテストはスタブ・一時ディレクトリ・捕捉した出力を使ってください。端末への生の OSC 出力を避けてください。

## 初版の仕様

- `zig build` で `zig-out/bin/ghostty-theme` を生成してください。
- テーマ名を引数で指定でき、引数なしでは fzf で選択できること。`-h` / `--help` も提供してください。
- Ghostty CLI の `+list-themes --plain --path` を使って一覧を取得し、名前に空白を含むテーマを扱ってください。同名テーマは一覧で重複させず、user を resources より優先してください。
- 適用前に `+validate-config --config-file=<path>` を実行してください。検証失敗時には OSC を一切出力しないでください。
- 現行版の palette と5種類の色キーの OSC 出力、および適用完了メッセージを維持してください。既存 snapshot と比較できるよう、出力順序とバイト列を維持してください。`cursor-text` は適用対象外です。
- コメント・空白・不正な5桁の色・最終改行がない入力を扱ってください。Ghostty の設定言語全体を新規実装する必要はありません。
- fzf の終了コード 1 / 130 は無出力・終了コード0とし、それ以外の失敗は診断と非0終了で伝えてください。
- テーマ不在は終了コード1、必要な CLI 不在は127としてください。一覧取得・検証の失敗を成功として扱わないでください。
- fzf のライブプレビューを維持してください。初版では既存 `executable_ghostty-theme-preview` を Bash 5+ で呼ぶことを許可します。配置・呼び出し方法を README に説明し、空白を含むパスでも動かしてください。選択・解析・適用そのものを既存 Bash 版に委譲することは不可です。
- 上記以外で現行版との互換性判断が必要なら、現行挙動を優先し、意図的な差異を記録してください。

## 検証と完了報告

- `zig build` と `zig build test` が成功すること。
- 自動テストは生成した Zig バイナリを実際に起動し、成功時の snapshot、同名テーマ優先、空白入りテーマ名、キャンセル、一覧取得失敗、検証失敗を確認してください。
- 既存 Bats helper は Bash 版を起動します。そのまま既存テストを通しても Zig 版の検証にはなりません。必要な adapter / テストは実験ディレクトリ内に作成してください。既存の期待値を実装に合わせて変更しないでください。
- 既存 fzf スタブは preview コマンドを実行しません。preview の引数・パスの取り扱いは別途確認してください。
- README にビルド・テスト・手動試用手順と制限を追記してください。
- 最終報告に、実装内容、実行した検証と結果、未検証事項、互換性の差異を記載してください。実際の Ghostty 上での適用は未実施として区別してください。
