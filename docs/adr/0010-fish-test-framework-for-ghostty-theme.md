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
- **手書きの assert 関数 + fish ネイティブランナー**: 外部依存ゼロ。`fish -c` による subprocess 隔離で function/変数の汚染も防げる。想定ケース数（17 件）に対して `assert.fish` は 30 行程度で収まる

また本番関数に対するテストアクセスが必要だが、`themes_dir` が `/Applications/Ghostty.app/...` にハードコードされているため、テストから fixture ディレクトリを読ませるフックが無い。

fzf 対話経路は一見 CI で検証しにくいが、本関数の fish 固有ガード（`pipestatus` 二段目で fzf exit code を分類、`command ls` による ls wrapper 回避、選択値を argv 経由で渡す shell-quoting）は **すべてこの経路に集中している**。ADR が謳う「fish 固有 gotcha の回帰検出」を成立させるには、最小限の stub で fzf 経路も検証する必要がある。

## Decision

以下を採用する。

1. **テストフレームワークは自作**: `tests/fish/{run,assert}.fish` として配置。依存は fish と coreutils の `diff` のみ。
2. **ディレクトリ構成**:
   ```
   tests/fish/
   ├── run.fish                    # discovery + runner, UPDATE_SNAPSHOTS=1 honored
   ├── assert.fish                 # assert_equal / assert_status / assert_match / assert_snapshot / assert_summary
   ├── bin/fzf                     # minimal fzf stub (selection value / exit code via env vars)
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
6. **テスト対象（ハイブリッド方針）**:
   - `ghostty-theme` の引数パス（positive / negative / edge 全 9 ケース）
   - `__ghostty_theme_preview`（positive / negative / edge 全 6 ケース）
   - `ghostty-theme` の **no-arg/fzf 経路は stub 経由で最小 2 ケースのみ**: 選択値の argv 引き渡し（exit 0）と cancel 伝搬（exit 130 → 親 return 0）。fzf 自体の全挙動は stub では再現しないため、`--filter` や `--preview` の相互作用に関する回帰は検出範囲外。
7. **fzf stub**: `tests/fish/bin/fzf` に fish 製の stub を置く。環境変数 `FAKE_FZF_SELECT`（stdout に返す選択値）と `FAKE_FZF_EXIT`（終了コード、省略時は 0）で挙動を制御。`run.fish` が子プロセス起動時に `PATH=tests/fish/bin:$PATH` を注入する。`command ls` ガードは stub に渡る stdin に fixture 由来の生のファイル名が到達することを検証することで副次的にカバーする（fish の embedded `ls` 関数を介していれば色コードが混入する）。
8. **CI**: `.github/workflows/ci.yml` に `fish-tests` ジョブを追加。Ubuntu runner に apt で fish をインストール、`fish -n` による構文チェックと `fish tests/fish/run.fish` によるテスト実行を行い、`ci-summary` の `needs` に加える。
9. **ローカルと CI の実行コマンドを統一**: 双方とも `fish tests/fish/run.fish` を直接呼び出す。Makefile 等のビルド抽象は導入しない。
10. **配布範囲から除外**: `.chezmoiignore` に `tests` を追加し、`chezmoi apply` で `$HOME` に配布されないようにする。

## Consequences

### Positive

- `ghostty-theme` のパースロジックと `__ghostty_theme_preview` のレンダリングに回帰検出網がかかる
- fish 固有ガード（`pipestatus` / `command ls` / fzf cancel の exit 130 処理）の最重要 2 分岐を fzf stub 経由で自動検証できる
- 外部依存を増やさない。CI runner の `apt install fish` だけで完結
- snapshot 方式により OSC / ANSI のような長い出力も「意図的な変更 vs 偶発的な変更」を git diff で明示的に区別できる
- subprocess 隔離により fish の関数名 / 変数の衝突を考慮せずにテストを増やせる

### Negative

- 自作ゆえ、framework 自体のバグや表現力不足が表面化すれば `assert.fish` / stub に手を入れる必要がある（ただし合計 50 行規模なので負担は小さい）
- fzf stub は stdin のファイル名列挙と終了コード伝搬のみを再現する。`--preview` コマンドが正しく起動するか、`--layout`・`--select-1` 等のフラグが期待通り効くかは範囲外で、回帰検出できない
- Snapshot 更新が必要な変更ではレビュー時に `.expected` ファイルの差分を目視する運用が発生する

### Risks

- GitHub Actions の Ubuntu runner で将来配布される fish バージョンが古く、テストコードで使う構文が動かなくなる可能性。発生時は `run.fish` 冒頭でバージョンチェックして明示的に fail する
- `ghostty-theme` 側の `GHOSTTY_THEMES_DIR` 追加は本番経路にも影響する env var 参照を増やす。万が一ユーザーが同名の env var を誤って設定していれば本番動作が変わる。影響は `test -d` で即時エラーになるため silent failure には至らない
- fzf stub の挙動が実物と乖離した場合、stub テストが PASS でも実 fzf では壊れる可能性。stub は「本関数が fzf 由来の値をどう扱うか」の契約だけを模倣する責務で、fzf 自体の動作変化は手動テストと実使用で捕捉する
