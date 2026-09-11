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
