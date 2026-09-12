# Ghostty theme selector comparison

現行 Bash 版を参照した Zig 移植の比較実験です。この worktree には、テーマの一覧取得・選択・解析・OSC 適用を Zig で実装した試作版を追加しています。プレビューのみ既存 Bash 版を利用します。

## ビルドと自動検証

実験ディレクトリで実行します。Zig 0.16.0、テスト用 Python 3、Bash 5+ が必要です。追加の Python パッケージは不要です。

```bash
cd experiments/ghostty-theme-zig
export ZIG_GLOBAL_CACHE_DIR="$PWD/results/zig-global-cache"
zig version  # 0.16.0
zig build
zig build test
```

生成物は `zig-out/bin/ghostty-theme` です。`zig build test` はビルドした Zig バイナリを直接起動します。既存 Bats helper が起動する Bash 版を移植版の合格判定に使いません。Zig 0.16 の `std.process.Init` / `std.Io` を使用しています（[公式リリースノート](https://ziglang.org/download/0.16.0/release-notes.html)）。

Linux aarch64 / Zig 0.16.0 で `zig build` と自動テスト19件が成功しました。テストは HOME・一時ファイル・CLI スタブを専用ディレクトリに隔離し、stdout / stderr を捕捉します。

- 既存 snapshot 4種とのバイト比較（Bats が取り除く末尾改行1個だけを期待値に補う）
- user 優先・一覧の重複排除・空白入り名前・最終改行なし・不正な色・`cursor-text` 除外
- fzf の選択・キャンセル 1 / 130・異常終了、CLI 不在、一覧取得・検証失敗の終了コードと無出力
- preview コマンドを実行する専用スタブで、既存 Bash preview の出力と user 優先を確認
- 空白・単一引用符・シェル構文を含む名前とパス、隣接 helper / PATH fallback、相対 TMPDIR、一時ファイルの後片付け

## 手動試用

引数指定は Ghostty CLI、対話選択はさらに fzf と Bash 5+ が必要です。インストールせずに、実験ディレクトリから既存 preview を明示できます。

```bash
export BASH5_BIN="$(command -v bash)"  # Bash 5+ を指すこと
export GHOSTTY_THEME_PREVIEW="$PWD/../../dot_local/bin/executable_ghostty-theme-preview"
./zig-out/bin/ghostty-theme --help

# 出力を保存して確認する。端末には OSC を直接出さない。
./zig-out/bin/ghostty-theme 'Test Spaces' >results/theme-output.bin
python3 -c 'from pathlib import Path; print(repr(Path("results/theme-output.bin").read_bytes()))'
```

`Test Spaces` はテスト fixture 名です。上記の通常実行では、実環境の `ghostty +list-themes --plain` が報告する名前に置き換えてください。CLI は `GHOSTTY_RESOURCES_DIR` 等の環境を継承します。

実際の Ghostty 内で適用を試す場合だけ、リダイレクトを外して `./zig-out/bin/ghostty-theme 'テーマ名'` を実行します。引数なしの `./zig-out/bin/ghostty-theme` は fzf を開きます。選択後に現在の surface の色を変更しますが、設定ファイルは書き換えません。**今回、実際の Ghostty 上での適用・実 fzf の対話操作は未実施です。**

preview の解決順は `GHOSTTY_THEME_PREVIEW` → バイナリと同じディレクトリの `ghostty-theme-preview` → PATH 上の `ghostty-theme-preview` です。隣接配置する場合は既存 `executable_ghostty-theme-preview` をその名前で置きます。実装は `BASH5_BIN`（未指定なら PATH の `bash`）で helper を呼ぶため、helper の実行ビットは不要です。helper パス、Bash パス、一時マップのパスは個別にシェル引用し、テーマ名の `{}` 置換は fzf に任せます。`GHOSTTY_THEME_PREVIEW` を指定すると確実に今回の参照 helper を利用できます。

## 制限と互換性の差異

- OSC の順序・大文字小文字・palette index の表記・完了メッセージは現行版と一致します。最初の引数だけを使い、空文字なら fzf を開く挙動も維持しています。
- 一覧取得失敗時は再実行せず、最初の呼び出しで捕捉した stderr と終了コードを報告します。診断の文言は完全互換ではなく、macOS のアプリ配置に応じた PATH 案内も省略しています。
- fzf のキャンセルでは stdout と stderr を両方破棄します。異常終了時は捕捉した stderr を診断とともに表示します。Bash 5 の確認を対話選択前に行い、古い Bash は終了コード2にします。
- 全テーマ内容と OSC をメモリに読み込んでから出力します。一覧とテーマファイルは16 MiB、CLI stderr と選択結果は1 MiBまでです。上限超過や読み込み失敗は非0終了になります。通常終了時に一時ディレクトリを削除しますが、強制終了では残る可能性があります。
- Ghostty の設定言語全体を解釈しません。現行版同様、対象キーの `#RRGGBB` と palette のみを読み、インラインコメント付きの色行や include による色は適用しません。タブ・改行を含む名前やパスは一覧 / TSV 形式の対象外です。
- preview helper の内容や個々の preview の成功を親プロセスでは検証しません。helper を正しく配置してください。Windows、macOS、実 Ghostty CLI / terminal、実 fzf の TTY 描画は未検証です。
- 管理対象スクリプト・設定・既存テスト / snapshot は変更していません。実装・検証では `chezmoi apply` とインストールを行っていません。

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
