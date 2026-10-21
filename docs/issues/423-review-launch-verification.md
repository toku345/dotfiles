# Issue #423：常設レビュー指示と Claude 起動の実機確認

## 対象と状態

- 対象は [#423](https://github.com/toku345/dotfiles/issues/423) の4項目。検証時の main は `6ab46a867fa51410c7c5844f8b25f061cba6d027`（[#424](https://github.com/toku345/dotfiles/pull/424)）。[手動往復の試行](418-handoff-trial.md)とは別の検証である。
- codex-cli 0.163.0、Claude Code 2.1.305、macOS で実施した。Codex exec の記録には正確なモデル ID が開示されていない。Claude の assistant 記録は `claude-opus-5-5`、使用量は `claude-opus-5-5[1m]` を報告した。
- source と実ホームの `~/.codex/AGENTS.md`・`~/.claude/CLAUDE.md`・Claude の `codex-usage/SKILL.md` は byte 一致していた。追加 apply は不要だった。
- 実ホームの認証用 HOME を維持し、コード・計画ファイルは隔離した。通常の CLI cache/history 更新はあり得る。生ログや認証情報はこの文書へ保存しない。

## 4項目の観測

| 項目 | 観測と制限 |
| --- | --- |
| 実ホームの常設指示 | project 用の指示を置かない新規セッションで、両ツールが計画・PR 本文案を作成し、追加のレビュー催促なしにセルフレビューを報告した。Codex は実ホームの AGENTS.md も読み、Claude は開始時に CLAUDE.md が渡されたと報告した。将来の遵守や本文の正確さの保証ではない |
| read-only caller → Claude | approval `never` では heredoc の一時ファイル作成が拒否され、stdin パイプによる実起動も `Not logged in` で失敗した。caller を read-only のまま `on-request` / `approvals_reviewer=auto_review` とし、Claude 起動コマンドだけを通常の承認経路で sandbox 外へ出した回は、レビュー取得・指摘の採否判断・計画への反映まで成功した |
| CLI 不在時 | Codex の一時的な shell PATH から Claude を除き、login shell を無効化した。`command -v claude` が終了1となり、絶対パスで迂回せず外部レビュー未実施を明示してセルフレビューした。ホスト全体のアンインストールや、Claude 側で Codex が不在のケースは試していない |
| レビュー専任での調査 | 両ツールが公式ページと Skill 本文を実参照した。ただし Claude の既定の回では再委譲禁止中に server-side `advisor` が呼ばれた。後述の公式環境変数を使った新規レビューでは、必要な調査を保ったまま advisor・再委譲・編集の呼び出しなしを観測した |

## advisor の制御

`advisor` は Codex CLI の起動ではなく、Anthropic の server tool である。検証時の user 設定は `advisorModel: "fable"` で、既定の実行記録には `server_tool_use` の `advisor` と `claude-fable-5-1` の使用量があった。

`--disallowedTools advisor` は採用しない。呼び出しなしの回はあったが、後の起動で「matches no known tool」と警告されたため、この指定で制御できた証拠にはならない。

[公式手順](https://code.claude.com/docs/en/advisor#turn-the-advisor-off)は `CLAUDE_CODE_DISABLE_ADVISOR_TOOL=1` による機能自体の無効化を提供する。レビュー専用の子プロセスに限って付ける。

```bash
env CLAUDE_CODE_DISABLE_ADVISOR_TOOL=1 \
  claude -p --permission-mode plan < /path/to/review-request.txt
```

これは caller の sandbox 外起動を指定するコマンドではない。sandbox 外起動が認証に必要な環境では、このコマンド全体を通常の承認経路へ渡す。caller の sandbox 制限、Claude 自身の plan 権限・sandbox は維持する。承認不能・拒否時は未実施と報告し、bypass や恒久 allowlist へ切り替えない。

read-only caller では heredoc が一時ファイルを必要として失敗することがある。長い依頼は、既存ファイルのリダイレクトまたは一時ファイルを作らない stdin パイプで渡す。

## 公式環境変数と sandbox 外起動を合わせた最終確認

ユーザーの依頼により、新規 Codex caller を read-only / on-request / auto_review で起動した。caller は次の Claude 起動1コマンドだけを通常の承認審査へ渡し、既存の依頼ファイルを stdin に使った。記録用 JSON は source 外の一時ディレクトリへ保存した。

```bash
env CLAUDE_CODE_DISABLE_ADVISOR_TOOL=1 \
  claude -p --permission-mode plan --no-session-persistence \
  --output-format json --settings /path/to/isolated-settings.json \
  < /path/to/review-request.txt > /path/to/review-result.json
```

このレビューは、上記の起動方針を `private_dot_codex/AGENTS.md` に反映する実装計画のレビューも兼ねた。

- 子の読み取り Bash 出力で環境変数の値 `1` を確認した。環境変数全体や認証情報は出力しなかった。
- WebFetch が公式の advisor ページを実際に取得した。Read が `plan-review-handoff/SKILL.md` と相対参照の `references/procedure.md`、変更前の source 指示を読んだ。
- 呼び出し元が JSON の実イベントを確認し、`server_tool_use advisor` は0、Agent/Task/Write/Edit/ExitPlanMode の呼び出しも0だった。使用量のモデル欄は `claude-opus-5-5[1m]` のみで、Fable の使用量はなかった。これは当該実行の観測であり、レビュアーの自己申告だけを根拠にしていない。
- Claude は plan mode が計画ファイル作成やサブエージェントを促したと報告したが、依頼文の禁止に従って実行しなかった。plan mode だけで全書き込みが禁止されるとは扱わない。
- isolated plan directory は空のまま。実ホームの plans ディレクトリも、実行前後のファイル名・mtime・size の集合が一致した。fixture の3ファイルは集合と SHA-256 が一致し、source は変更前の clean なままだった。
- `~/.claude/settings.json` の SHA-256 は実行前後で一致し、保存済みの `advisorModel: "fable"` は維持された。通常の advisor を恒久無効化していない。

## 計画レビューの採否と残る制約

- 「計画ファイル・再委譲禁止が実際に守られたか、caller 側で確認する」を採用し、上の JSON とファイル状態の確認を行った。
- 「レビュアーが advisor を見なかっただけでは0回の証拠にならない」を採用し、caller 側の実イベント・使用量・環境変数値と公式仕様を分けて記録した。
- Claude から caller の `sandbox_permissions` は見えない、という制限を記録する。caller の設定・承認経路と子の認証成功は呼び出し元側で観測した。OS の境界全体を監査したものではない。
- 承認できない read-only / never の起動失敗は、その条件の制限として残す。認証・権限を緩めて成功に読み替えない。
- 新しい起動手順は source の更新であり、実ホームへの追加 apply は別途承認が必要。Desktop・Fugu、全 CLI 版、すべての Skill の副作用や将来の遵守は検証していない。
