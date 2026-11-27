# Claude Code プラグイン

`chezmoi apply` では Claude Code のプラグインは自動インストールされません。新しいマシンや環境では手動セットアップが必要です。

## 人が編集する計画レビュー

`/plan-review-handoff` に `prepare` / `review` / `assess` と対象を添え、依頼文の準備・受け取った計画のレビュー・元の作成元での採否判断を行う。[共通手順と依頼文](plan-review-handoff.md)は Codex と共有し、`~/.claude/skills/plan-review-handoff/` へ生成する。

依頼文と結果はユーザーが編集可能な状態で手動転送する。この Skill は相手を自動起動せず、通常の自動計画レビューや pre-PR gate も置き換えない。

## 別セッションへの通信

独立した別セッションへの通信は、ユーザーが明示的に頼んだときだけ行う。現在のタスク配下のサブエージェント通信は対象外とする。

### Claude 標準通信の受信

ユーザー設定の `crossSessionInbound` は `refuse` とし、既定で受信を拒否する。
受信が必要なセッションだけ次のように起動する:

```bash
claude --settings '{"crossSessionInbound":"accept"}'
```

project-local の `refuse` はこの上書きより優先されるため、既定値はユーザー設定に置く。
`accept` は特定の送信者だけを許可する設定ではない。
また、`refuse` は送信禁止ではないため、標準通信による送信もユーザーの明示依頼時だけ行う。
詳細は [Claude Code のセッション間通信](https://code.claude.com/docs/en/cross-session-messaging) を参照する。

通常起動での受信拒否と `accept` 指定時の受信確認は専用 Claude セッションで行い、未実施なら未検証として記録する。

## 定期更新チェックリスト

Claude Code plugins は自動更新しない
(`DISABLE_AUTOUPDATER=1` は維持)。
四半期に 1 回を下限として、同じレビュー窓で更新有無を確認する。変更と
rollback を分離するため、実際の bump はコンポーネントごとに reviewed PR を
作る。レビュー窓は [docs/security.md の high-privilege CLI 四半期 pin
レビュー](security.md#high-privilege-clis-and-casks) に相乗りし、upstream の
動きが速くなったら月次に短縮してよい。

### Claude Code plugins

policy と詳細 runbook は [docs/security.md の Claude Code and Codex
セクション](security.md#claude-code-and-codex-ai-coding-tools) が正。要点のみ:

- before: `claude plugin list --json` で現行 version / SHA を記録する
- 対象 plugin の release notes / source diff をレビューする
- `claude plugin marketplace update <marketplace>` →
  `claude plugin update <plugin>@<marketplace>` (反映は Claude Code 再起動後)
- after: `claude plugin list --json` を再取得して差分を記録する
- 対象 plugin 固有の smoke test を実施する (例: `pr-review-toolkit` 更新時は
  trivial branch で小さく `/pr-review` を回す)

### bump PR の検証

- `sh -n` + `shellcheck` (変更した `.chezmoiscripts/*.sh`)
