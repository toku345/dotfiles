# ADR 0011: Migrate `ghostty-theme` from fish to bash

## Status

Accepted (2026-04-22)

## Context

`ghostty-theme`（`private_dot_config/private_fish/functions/ghostty-theme.fish`）は現在 fish 関数として実装されている。ADR 0009 で OSC 経由の per-tab theme apply として設計され、ADR 0010 で fish-native テスト基盤（PR #140 で main に統合済み）が整備された。

本 ADR は、以下の課題に対する実装言語の判断を記録する。

### 課題

1. **ポータビリティ**: fish ユーザー以外（bash / zsh）には提供できない
2. **共有のしやすさ**: 他ユーザーに使ってもらうとき、fish インストールが前提条件になる
3. **テーマ発見ロジックのハードコード**: `/Applications/Ghostty.app/Contents/Resources/ghostty/themes` 直読みで、以下を取りこぼしている:
   - ユーザー定義テーマ (`~/.config/ghostty/themes`)
   - Linux・ソースビルド版の resources パス差分
   - Ghostty 側のテーマ発見ロジック更新への追従

### 検討した選択肢

| 選択肢 | 評価 |
|-------|------|
| **A. 現状維持（fish のまま）** | ポータビリティ問題を解決しない。テーマ発見ロジックの限界も残る |
| **B. libghostty 経由で書き直す** | 不適合。`include/ghostty.h` 冒頭で「general purpose embedding API ではない」と上流が明言、C ABI で fish/bash から直接呼べず FFI ラッパーが必要、抽象層は GPU サーフェス描画向けで theme ファイルの静的解析用途に合致しない。cmux のようにターミナル自体を埋め込む用途に最適化されている |
| **C. bash に移植（本 ADR の選択）** | 現在の実装が実質「既存 CLI を組み合わせて TTY に OSC を書く糊コード」であり、shell の本分。`[[ =~ ]]` と `BASH_REMATCH` で fish regex をほぼ 1:1 移植可能 |
| **D. Rust/Zig で独立 CLI 化** | オーバーエンジニアリング。本ツールの core 責務（CLI orchestration + OSC emission）は shell で完結する。`ratatui`/`syntect` を活かすリッチ TUI が不要な限り、コード量・複雑度が増すだけ |
| **E. POSIX sh 縛り** | regex と配列が必須の箇所（`palette N=#RRGGBB` パース、複数 key の OSC コード対応表）で `expr` と `case` の連鎖に退化し、可読性が著しく低下する |

### リッチプレビュー（`ghostty +list-themes` 級）の可否

`ghostty +list-themes` TUI のリッチさ（シンタックスハイライト付きコードサンプル、装飾テキスト、プロンプトモックアップ）を fzf preview で再現するには、**palette remap 変換器**（ANSI SGR の palette 番号参照を theme 固有の truecolor に書き換える小型ツール）が必要になる。これは pure bash/sed では SGR combinations の取り扱いで破綻しやすく、Rust/Go 製の補助バイナリが事実上必須になる。

本 ADR は **リッチプレビューを要件から除外する**。現 `__ghostty_theme_preview` 相当（パレット swatches + hex 表示）を bash でも維持するのみとする。

## Decision

以下を採用する。

1. **`ghostty-theme` を bash で再実装し、fish 実装を置き換える**
   - 配置: `dot_local/bin/executable_ghostty-theme`（chezmoi で `~/.local/bin/ghostty-theme` に executable 配布、既に PATH 通過済み）
   - Shebang: `#!/usr/bin/env bash`
   - bash 4+ 想定（macOS の古い bash 3.2 は対象外）。`#!/usr/bin/env bash` で Homebrew bash 5 を優先、`set -euo pipefail` を有効化

2. **テーマ発見を `ghostty +list-themes --plain --path` に委譲**
   - ハードコードパスと `GHOSTTY_THEMES_DIR` の自前 env var を廃止
   - 出力 `<name> (resources|user) <path>` を name↔path ペアとしてパース
   - user / resources 重複時は Ghostty の precedence（user 優先）を尊重: 同名を検出した場合は user 側 path を採用

3. **apply 前に `ghostty +validate-config --config-file=<theme>` で事前検証**
   - ⚠️ **`=` 区切り必須**（スペース区切り `--config-file <path>` は手元 Ghostty で常に exit 1 になり機能しない。Codex レビューで検出）
   - 壊れた theme を OSC 適用する前に fail-loud 停止
   - stderr に常時出る `error: SentryInitFailed` は成否判定には無関係（exit code のみで判断）

4. **fzf によるインタラクティブ選択を維持**
   - 既存の preview helper（`__ghostty_theme_preview.fish`）は bash 版 `ghostty-theme-preview` として `dot_local/bin/executable_ghostty-theme-preview` に配置
   - fzf preview 呼び出しも bash スクリプト経由に切替

5. **テストを fish-native → bats-core に移行**
   - 配置: `tests/bats/`
   - ADR 0010 で確立した fzf stub / fixtures / snapshots パターンを踏襲
   - 18 ケース相当をすべて移植
   - ローカル／CI 実行コマンド: `bats tests/bats/`

6. **CI `fish-tests` ジョブを `bats-tests` に置き換える**
   - Ubuntu runner に `bats-core` を apt で導入（`sudo apt-get install -y bats`）
   - `shellcheck` ジョブの対象ディレクトリに `dot_local/bin/` と `tests/bats/` を追加
   - `ci-summary` の `needs` を更新

7. **fish 実装を削除**
   - `private_dot_config/private_fish/functions/ghostty-theme.fish` 削除
   - `private_dot_config/private_fish/functions/__ghostty_theme_preview.fish` 削除
   - `tests/fish/` 削除
   - `private_dot_config/private_fish/completions/ghostty-theme.fish` は残すが、補完候補の取得を `ghostty +list-themes --plain` に変更（user theme が見える）

8. **リッチプレビュー要件は今回採用しない**
   - `ghostty +list-themes` 級の TUI 再現は見送り
   - 不足が顕在化した場合は、**別リポジトリでの Rust/Zig 独立実装** に踏み切る

## Trigger conditions for separate-repo Rust/Zig split

以下のいずれかが満たされた時点で、独立リポジトリへの分離と Rust（`ratatui` + `crossterm` + `syntect`）または Zig 実装を検討する。

- **外部利用者からの要望**: 「fzf を入れずに使いたい」「Windows で使いたい」
- **自分の使用頻度低下**: プレビュー不足で週 1 回未満の使用に低下
- **Ghostty 側の format 破壊的変更**: bash regex での追随が著しく複雑化
- **上流統合の機会**: `ghostty +apply-theme` 相当の本体統合余地が生まれた場合（この場合は Zig で upstream を直接ねらう）
- **期限到達**: **2026-10-22 に見直しレビュー**（本 ADR 採択から 6 ヶ月後）。使用満足度ギャップが残存していれば分離、なければ現状継続を明文化

分離時はコミット履歴を保つため `git filter-repo` で `dot_local/bin/executable_ghostty-theme*` と `tests/bats/` を抽出し、新リポジトリを立ち上げる。

## Consequences

### Positive

- **ポータビリティ獲得**: macOS / Linux の bash / zsh / fish 利用者すべてが導入可能
- **テーマ発見ロジックの健全化**: user theme と OS 差分を Ghostty 本体に委譲、ハードコードパス消滅
- **validate-config 統合**: 壊れた theme での sign-change を未然検知
- **`GHOSTTY_THEMES_DIR` 自前 env var の廃止**: Ghostty の `GHOSTTY_RESOURCES_DIR` 標準 env に一本化
- **配布容易性**: 将来 Homebrew tap 化するときも bash スクリプト単体なら tap 作成のコストが低い

### Negative

- **fish-native テスト基盤を退役**: ADR 0010 で構築したフレームワーク（fzf stub・snapshots・assert.fish）は bats 移行で再構築が必要。ただし設計原則（fzf 経路を最小 stub で covering / snapshot による OSC 出力の目視レビュー）は踏襲できる
- **bash 依存の導入**: POSIX sh 縛りよりも可読性を優先した結果、bash 4+ が前提になる（macOS 標準 bash 3.2 不可。ただし Homebrew bash があれば解消）
- **プレビューのリッチさ頭打ち**: `ghostty +list-themes` TUI 級の体験は得られない（明示的トレードオフ）

### Neutral

- fish completion (`completions/ghostty-theme.fish`) は残存。ただし内部 `ls` を `ghostty +list-themes --plain` に差し替える小改修あり

## Related ADRs

- ADR 0009: Ghostty per-tab theme via OSC（本ツールの設計根拠）
- ADR 0010: Fish-native test framework for `ghostty-theme`（本 ADR で退役、テスト設計原則は bats 版に継承）
