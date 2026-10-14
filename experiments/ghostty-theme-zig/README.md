# Ghostty theme selector comparison

現行 Bash 版を参照した Zig 移植を、GPT-6 と Sakana Fugu に同条件で依頼するための共通開始地点です。この準備段階には Zig 実装やビルドファイルを含めません。

## 固定する条件

- 参照実装のコミット: `ba13f1005aaecf250b7fbd10097c9c95d5116f63`
- 共通ベースブランチ: `experiment/ghostty-theme-zig-base`
- 作業ディレクトリ: `experiments/ghostty-theme-zig/`
- Zig: `0.16.0`（`.tool-versions`。asdf 利用時はこのディレクトリで `zig version` を確認）
- 共通依頼: [PROMPT.md](PROMPT.md)
- 既存版の基準確認: リポジトリルートで `bats tests/bats/test_ghostty_theme.bats`。準備時には18件成功。これは Bash 版の結果であり、移植版の合格を意味しません。

## 開始手順

準備コミット完成後、リポジトリルートで次を実行します。両方とも同じ不変のコミットから分岐します。兄弟ディレクトリは未使用のパスを選んでください。

```bash
comparison_base=$(git rev-parse experiment/ghostty-theme-zig-base^{commit})
git worktree add -b experiment/ghostty-theme-zig-gpt6 ../chezmoi-ghostty-gpt6 "$comparison_base"
git worktree add -b experiment/ghostty-theme-zig-fugu ../chezmoi-ghostty-fugu "$comparison_base"
```

各エージェントをそれぞれの worktree で開始し、`experiments/ghostty-theme-zig/PROMPT.md` を読んで実装するよう依頼します。相手の出力は渡さず、同じ参照ファイル・ネットワーク可否・ツール権限・追加指示を与えます。各 worktree の実験ディレクトリで `zig version` が `0.16.0` になることを実行前に確認してください。

worktree はホームディレクトリ・端末・グローバルキャッシュを分離しません。テストの HOME / 一時ファイルは専用ディレクトリにし、Zig のグローバルキャッシュも実行ごとに専用の `ZIG_GLOBAL_CACHE_DIR` を指定してください。テスト出力は捕捉し、実際のテーマ適用は最後に別々の端末で試します。worktree から `chezmoi apply` は実行しません。

## 比較の記録

各実行の開始前に、以下を記録します。生ログは Git 除外済みの `results/` に保存できます。

| 項目 | 記録内容 |
| --- | --- |
| 開始地点 | 共通ベースの完全なコミットOID |
| モデル | 正式なモデルID、推論設定、Fuguの種類 |
| 実行環境 | エージェント名・バージョン、OS、Zig / Bash / Batsのバージョン |
| 補助機能 | ツール、ネットワーク、追加の指示・スキル、サブエージェントの有無 |
| 予算 | 共通の時間上限と各サービスの費用上限を実行前に決定 |
| 結果 | ビルドと各動作の合否、実行時間、把握できる実費 |
| 人間の介入 | 追加指示・手修正の回数と内容 |
| 制限 | 未実装・未検証、既存版との意図的な差異 |

時間上限に達したら未完成部分を残したまま記録します。異なるエージェント環境で実行した場合は、モデル単体ではなくツールを含む作業体験の比較として扱います。採点では実動作・誤った成功判定の有無・必要な介入・変更しやすさを確認します。

## 配布との分離

`experiments/` は `.chezmoiignore` で配布対象外です。成果物はこのディレクトリ内に置き、既存の管理対象スクリプトや設定を置換しません。プレビューの Zig 移植、配布への組み込み、CI の変更は今回の初版の対象外です。

## Zig 試作版（実装結果）

`ghostty-theme` の選択・解析・検証・適用を Zig 0.16.0 で実装しました。fzf のライブプレビューだけは、既存の Bash 版 `ghostty-theme-preview` を Bash 5+ で呼び出します。変更範囲はこのディレクトリ内だけです。

### 構成

| パス | 内容 |
| --- | --- |
| `build.zig` / `build.zig.zon` | ビルド定義（`zig build` / `zig build test` / `zig build bats` / `zig build run`） |
| `src/main.zig` | CLI（引数・PATH 探索・Ghostty CLI 呼び出し・fzf・プレビュー連携・終了コード） |
| `src/theme.zig` | I/O を持たない処理（一覧解析と重複除去、OSC 生成）と単体テスト |
| `tests/e2e.zig` | 生成バイナリを実際に起動する E2E テスト（Bash 版との差分比較を含む） |
| `tests/stubs/ghostty`, `tests/stubs/fzf` | 実験用スタブ。既存スタブに委譲しつつ、失敗注入や `--preview` の実行を追加 |
| `tests/run-existing-bats.sh`, `tests/bats-adapter/` | 既存の `test_ghostty_theme.bats` を無改変のまま Zig 版に対して実行するアダプタ |

### ビルド

```bash
cd experiments/ghostty-theme-zig
zig version                      # 0.16.0
export ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-cache/global"   # 実行ごとに専用キャッシュ（任意）
zig build                        # zig-out/bin/ghostty-theme と zig-out/bin/ghostty-theme-preview
```

`zig build` は、バイナリのほかに `../../dot_local/bin/executable_ghostty-theme-preview` を `zig-out/bin/ghostty-theme-preview` として実行権限付きでコピーします。不要な場合は `-Dinstall-preview=false` を指定します。リリースビルドは `-Doptimize=ReleaseSafe` です。

### テスト

```bash
zig build test --summary all     # 単体テスト + E2E
zig build bats                   # 既存 Bats スイートを Zig 版に対して実行（bats が必要）
```

- E2E テストは Bash 5+ を必要とします（参照実装、プレビュー、スタブで使用）。PATH 上の `bash` が 4 以下の場合は `BASH5_BIN=/opt/homebrew/bin/bash` のように絶対パスを指定してください。条件を満たさない場合は skip せず失敗します。
- 各テストは `.zig-cache/tmp/` 以下に専用ツリー（パスに空白・`'`・`$HOME` を含む）を作り、HOME・TMPDIR・PATH・SHELL・LC_ALL を固定した環境で実行します。出力はすべて捕捉するため、端末に OSC は出力されません。
- 確認内容: 既存 snapshot 4 件とのバイト一致、cursor-text の除外、同名テーマの user 優先（引数・fzf の両経路、fzf 入力での重複なし）、空白入りテーマ名、fzf の 1 / 130 / SIGINT による無出力の正常終了、その他の fzf 失敗、fzf / ghostty 不在時の 127、一覧取得失敗（終了コード・シグナル・部分出力を含む）、テーマ 0 件、ディレクトリや空パスの拒否、検証失敗時に stdout が空であること、検証出力の順序保持、`--config-file=<path>` が 1 引数で渡ること、ヘルプ。
- 差分テストでは、同じスタブと環境で Bash 版と Zig 版を 31 シナリオ実行し、終了コード・stdout・stderr のバイト一致を確認します。シナリオには CRLF、最終改行なし、タブ・VT・FF、5 桁と 7 桁の色、末尾ゴミ、コメント、`'` や `$` を含む名前、正規表現の貪欲一致、user 優先、各種失敗を含めています。
- プレビューのテストでは `tests/stubs/fzf` を使います。このスタブは `--preview` の式を fzf と同様に `$SHELL -c` で実行し、`{}` を単一引用符で囲んだ候補に置き換えます。確認内容は、空白や引用符を含むインストール先・TMPDIR での実プレビュー出力の一致、`/bin/sh` と Bash での実行（zsh と fish は PATH にある場合だけ）、マップファイルの内容・0600 権限・終了後の削除、探索順、上書き用環境変数です。
- 境界条件として、2 万件の候補を読み込む前に fzf が 1 MiB を出力する場合のデッドロック防止、即時キャンセル、不正な TMPDIR、相対・空の PATH 要素、一覧の最終改行なし・user 先行の順序、16 MiB を超えるテーマ、検証成功時の出力抑制・シグナル終了・検証後のファイル消失も確認します。プレビューの候補名とパスには引用符・バックスラッシュ・`$(...)` を含め、シェル展開されないことを検証します。相対 TMPDIR に symlink と `..` が連続する場合も OS 本来のパス解決を保ちます。

### 手動試用

端末に OSC を出さずに確認する場合は、スタブを使って出力を可視化します。

```bash
repo=$(git rev-parse --show-toplevel)
PATH="$repo/tests/bats/bin:$PATH" GHOSTTY_TEST_THEMES_DIR="$repo/tests/bats/fixtures/themes" \
  ./zig-out/bin/ghostty-theme "Test Spaces" | cat -v
```

実際の Ghostty で試す場合は、Ghostty の端末で次を実行します。適用されるのは現在のサーフェスだけで、設定ファイルは変更しません。

```bash
./zig-out/bin/ghostty-theme --help
./zig-out/bin/ghostty-theme "<テーマ名>"     # ghostty +list-themes --plain の名前
./zig-out/bin/ghostty-theme                  # fzf + ライブプレビュー
```

### プレビューの配置と呼び出し

fzf の `--preview` に渡す式は次の固定文字列です。

```text
"$_GHOSTTY_THEME_PREVIEW_CMD" --map "$_GHOSTTY_THEME_PREVIEW_MAP" {}
```

プレビューコマンドのパスとマップファイルのパスは、式に埋め込まずに fzf の環境変数として渡します。`"$VAR"` 形式は sh・bash・zsh・fish で同じように展開されるため、空白・引用符・`$`・バックスラッシュを含むパスでも引用処理が壊れません。`GHOSTTY_THEME_PREVIEW_BASH` を指定した場合は、先頭に `"$_GHOSTTY_THEME_PREVIEW_BASH"` が付きます。

プレビューコマンドは次の順で決まります。

1. `GHOSTTY_THEME_PREVIEW`（明示的な上書き）
2. 起動パスと同じディレクトリにある実行可能な `ghostty-theme-preview`。Bash 版の `$0` と同じ扱いで、PATH 経由で起動した場合は PATH 上の位置を使い、symlink は解決しません。
3. 実体バイナリ（symlink 解決後）と同じディレクトリにある実行可能な `ghostty-theme-preview`
4. 素の `ghostty-theme-preview`（fzf のシェルが PATH から解決）

プレビュースクリプトの shebang は `#!/usr/bin/env bash` です。PATH 上で最初に見つかる bash が 4 以下（macOS の `/bin/bash` 3.2 など）の場合、プレビュー欄には Bash 版のバージョンエラーが表示されます。その場合は Homebrew の bash を PATH の前方に置くか、`GHOSTTY_THEME_PREVIEW_BASH=/opt/homebrew/bin/bash` を指定してください。この変数を指定すると、実行権限のないスクリプトも指定したインタプリタで実行できます。

普段使いで試す場合も、chezmoi 管理下の `~/.local/bin/ghostty-theme` は置き換えないでください（`chezmoi apply` で上書きされます）。代わりに、たとえば `ln -s "$PWD/zig-out/bin/ghostty-theme" ~/bin/ghostty-theme-zig` とします。この場合、symlink 側のディレクトリにプレビューがなければ、3 によって `zig-out/bin/ghostty-theme-preview` が使われます。

### Bash 版との意図的な差異

| 項目 | Bash 版 | Zig 版 | 理由 |
| --- | --- | --- | --- |
| `--preview` の式 | パスを `printf %q` で式に埋め込む | 固定式とし、パスは環境変数（`_GHOSTTY_THEME_PREVIEW_CMD` / `_MAP` / `_BASH`）で渡す | `%q` は bash 用の引用で、`$SHELL` が fish などの場合に壊れる可能性があるため。fzf の子プロセスからこれらの変数が見える |
| プレビュー探索 | `$0` と同じディレクトリ → PATH | 上書き用環境変数 → 起動パスと同じディレクトリ → 実体と同じディレクトリ → PATH | `zig-out/bin` への symlink 運用で、追加設定なしにプレビューを使えるようにするため |
| 一覧取得失敗時 | stderr を捨てて実行し、失敗したら stderr を表示するため再実行 | 1 回だけ実行して stderr を捕捉し、失敗時だけ再出力 | 二重実行を避けるため。決定的な失敗であれば出力は同じ |
| 名前が空の一覧行（` (user) /path`） | `bad array subscript` で異常終了（終了コード 1） | その行を無視 | 選択できない行であり、他のテーマまで使えなくなるのを避けるため |
| fzf が状態 0 で空の選択を返す | `bad array subscript` で異常終了（終了コード 1） | `theme '' not found` として終了コード 1 | 終了コードは同じで、診断を明確にするため |
| 空白の判定 | ロケール依存の `[[:space:]]` | ASCII の空白（space, tab, VT, FF, CR）だけ | ロケールに依存しないため。UTF-8 の不正バイトを含む一覧行も、Bash（UTF-8 ロケール）と違ってそのまま解析する |
| 子プロセスを起動できない場合 | bash の `command not found` / `Permission denied` | `ghostty-theme: failed to run '<path>': <Error>` を追加し、126 / 127 を同じ経路で扱う | 診断の明確化。失敗を成功として扱わない点は同じ |
| fzf 実行中の SIGINT / SIGQUIT | bash の既定動作 | 親プロセスは no-op ハンドラで生存し、fzf の結果（130 なら無出力の終了コード 0）で判断してマップファイルを削除 | 一時ファイルを残さないため。ハンドラは exec 時に既定動作へ戻るため fzf には影響しない。元々 ignore されているシグナルは変更しない |
| fzf への候補入力 | パイプ | 0600 の一時ファイルを作成後すぐ unlink し、その開いた descriptor を stdin に渡す | fzf の入力と出力が共にパイプ容量を超えてもデッドロックしないため。候補の順序・バイト列は同じで、ファイル名は fzf 起動前に削除する |
| テーマファイルの読み込み | 1 行ずつ読みながら出力 | 全体を読んでから一括出力（固定サイズ上限なし） | 読み込みエラー時に一部だけ適用された状態を残さないため。ファイルサイズに比例するメモリを使う |
| 一時マップファイル名 | `mktemp` の既定名 | `$TMPDIR/ghostty-theme.<16桁hex>`（0600、排他作成） | 名前以外は同等 |
| PATH 未設定時 | bash の既定 PATH | `/usr/local/bin:/usr/bin:/bin` | 実用上の差は小さい |

上記の意図的な差異を除き、差分テストの対象範囲ではヘルプ文、診断メッセージ、終了コード、OSC のバイト列と順序は Bash 版と同じです。

### 制限・未検証

- 実際の Ghostty 上での適用は未実施です。OSC のバイト列は snapshot と Bash 版との比較だけで確認しています。
- 実物の Ghostty CLI（`+list-themes` / `+validate-config`）との結合は未確認で、スタブだけで確認しています。
- macOS は `aarch64-macos` / `x86_64-macos` 向けのクロスコンパイル成功だけを確認しており、実行は未確認です（特に「実体と同じディレクトリ」の探索）。
- fish・zsh でのプレビュー式は、実行環境にない場合は自動テストで実行されません。この環境では `/bin/sh` と Bash だけで確認しました。
- 本物の fzf の対話操作は自動テストに含まれていません。自動テストでは、fzf と同じ規則で preview の式を実行するスタブを使っています。手動では fzf 0.74.4 を擬似端末（`script`）上で起動し、`SHELL=/bin/sh` と Bash の両方で確認しました。確認内容は、空白・`'`・`$HOME` を含むパスでのプレビュー実行、SIGINT による無出力の終了コード 0、マップファイルの削除です。
- fzf 実行中に SIGTERM・SIGHUP・SIGKILL で終了した場合、マップファイルが TMPDIR に残ることがあります（Bash 版の `trap EXIT` も SIGKILL では動作しません）。
- プレビューの Zig 移植、配布（chezmoi）への組み込み、CI への追加は対象外です。
