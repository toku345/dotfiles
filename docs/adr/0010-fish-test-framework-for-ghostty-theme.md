# ADR 0010: Fish-native test framework for `ghostty-theme`

## Status

Accepted

## Context

`ghostty-theme` と `__ghostty_theme_preview`（`private_dot_config/private_fish/functions/`）は、Ghostty のバンドルテーマを OSC シーケンスで現在のサーフェスに適用する fish 関数である。PR #136 で実装がマージされたが、テストは付いていない。以下の性質上、回帰が顕在化しにくい:

- 出力が制御シーケンス（OSC）で、目視検証が難しい
- パースロジックが正規表現の連鎖で、入力バリエーション（コメント、空白、hex 大小、桁数不正）で挙動が分岐する
- `pipestatus` や fzf exit code、`command ls` 対策など fish 固有の落とし穴を踏んでおり、これらのガードが将来の変更で壊れても静かに失敗する恐れがある

自動テストを入れるにあたり、fish 用のエコシステムから候補を比較した。

- **fishtape**: 更新が長期停滞、採用は将来負債になる
- **bats-core**: bash 用。fish 関数をテストするには `fish -c` でラップが必要で、出力・エラーの取り回しが不自然
- **手書きの assert 関数 + fish ネイティブランナー**: 外部依存ゼロ。`fish -c` による subprocess 隔離で function/変数の汚染も防げる。想定ケース数（15 件）に対して `assert.fish` は 30 行程度で収まる

また本番関数に対するテストアクセスが必要だが、`themes_dir` が `/Applications/Ghostty.app/...` にハードコードされているため、テストから fixture ディレクトリを読ませるフックが無い。

## Decision

以下を採用する。

1. **テストフレームワークは自作**: `tests/fish/{run,assert}.fish` として配置。依存は fish と coreutils の `diff` のみ。
2. **ディレクトリ構成**:
   ```
   tests/fish/
   ├── run.fish                    # discovery + runner, UPDATE_SNAPSHOTS=1 honored
   ├── assert.fish                 # assert_equal / assert_status / assert_match / assert_snapshot / assert_summary
   ├── fixtures/themes/            # TestDark / TestMinimal / TestMixed / "Test Spaces"
   ├── snapshots/
   │   ├── ghostty-theme/*.expected
   │   └── preview/*.expected
   ├── test_ghostty_theme.fish
   └── test_preview.fish
   ```
3. **Subprocess 隔離**: `run.fish` が各テストファイルを `fish -c "source assert.fish; source $file"` で別プロセス起動し、function / グローバル変数のテスト間汚染を防ぐ。
4. **Expected 値**: 長い出力は snapshot ファイル、短い文字列（エラーメッセージ等）はインラインで `assert_match`。`UPDATE_SNAPSHOTS=1` で上書き生成、目視レビュー後にコミット。
5. **本番コードの最小リファクタ**: `ghostty-theme.fish` に `GHOSTTY_THEMES_DIR` env var override を追加する。未設定時は従来のハードコードパスにフォールバック（本番 zero-config UX 維持）、設定時は無条件でその値を使用（空文字 / 不正パスは既存の `test -d` エラーで fail-loud）。`__ghostty_theme_preview` は既に引数でパスを受ける設計のため改修不要。
6. **テスト対象**: `ghostty-theme` の引数パスと `__ghostty_theme_preview` のみ。fzf 対話経路はヘッドレス CI で再現不能のため範囲外（将来 `--filter` + `--select-1` 方式でのヘッドレス化余地はあるが今回は YAGNI）。
7. **CI**: `.github/workflows/ci.yml` に `fish-tests` ジョブを追加。Ubuntu runner に apt で fish をインストール、`fish -n` による構文チェックと `fish tests/fish/run.fish` によるテスト実行を行い、`ci-summary` の `needs` に加える。
8. **ローカルと CI の実行コマンドを統一**: 双方とも `fish tests/fish/run.fish` を直接呼び出す。Makefile 等のビルド抽象は導入しない。
9. **配布範囲から除外**: `.chezmoiignore` に `tests` を追加し、`chezmoi apply` で `$HOME` に配布されないようにする。

## Consequences

### Positive

- `ghostty-theme` のパースロジックと `__ghostty_theme_preview` のレンダリングに回帰検出網がかかる
- 将来の fish gotcha（`pipestatus` / `command ls` / `fzf` exit code など）に関する修正を加える際、既存挙動を壊したかを自動検出できる
- 外部依存を増やさない。CI runner の `apt install fish` だけで完結
- snapshot 方式により OSC / ANSI のような長い出力も「意図的な変更 vs 偶発的な変更」を git diff で明示的に区別できる
- subprocess 隔離により fish の関数名 / 変数の衝突を考慮せずにテストを増やせる

### Negative

- 自作ゆえ、framework 自体のバグや表現力不足が表面化すれば `assert.fish` に手を入れる必要がある（ただし 30 行規模なので負担は小さい）
- fzf 経路が未テストなため、対話入力に関する回帰は検出できない（手動確認に委ねる）
- Snapshot 更新が必要な変更ではレビュー時に `.expected` ファイルの差分を目視する運用が発生する

### Risks

- GitHub Actions の Ubuntu runner で将来配布される fish バージョンが古く、テストコードで使う構文が動かなくなる可能性。発生時は `run.fish` 冒頭でバージョンチェックして明示的に fail する
- `ghostty-theme` 側の `GHOSTTY_THEMES_DIR` 追加は本番経路にも影響する env var 参照を増やす。万が一ユーザーが同名の env var を誤って設定していれば本番動作が変わる。影響は `test -d` で即時エラーになるため silent failure には至らない
