# Codex / Claude Code の permission 方針

自動審査を使いながら、重要操作の判断はユーザーが保持する。通常のローカル編集と関連検証は、合意した範囲内で進める。

## 会話で合意する操作

commit・push・apply・共有先への書き込みは、対象・内容・影響を示して明示合意を待つ。CLI、MCP、app のどの経路でも同じ原則を適用する。同じ会話で対象と操作を明示承認済みなら、その範囲で会話上の確認を重ねない。対象や影響の変更、Skill の着手・引き渡し確認、リポジトリ固有の要件は別途守る。

管理元を編集する合意は、live apply、管理外ルールの清掃、commit、push、PR 作成を一括で許可するものではない。共有先への書き込み後は read-back で確認する。Confluence ページ更新・Jira 編集も対象とし、履歴から復元できることだけでは未合意の共有書き込みを正当化しない。同じページ・issue への反復更新は、対象・目的・操作が明示合意の範囲内なら会話上の確認を毎回繰り返さない。

この停止点は agent 指示による運用であり、全経路を強制的に遮断する仕組みではない。自動審査の許可はユーザーの実行合意を代替せず、会話での合意もツールの承認画面を省略する保証にはならない。ブロックを避ける目的でコマンド形やツールを切り替えない。

## 実装と限界

| 項目 | Codex | Claude Code |
|---|---|---|
| 管理元の指示 | `private_dot_codex/AGENTS.md` | `private_dot_claude/CLAUDE.md` |
| 通常の制限 | `workspace-write`、通常コマンドのネットワーク無効 | Bash sandbox 有効、`defaultMode: auto` |
| 審査への経路 | `on-request`、自動 reviewer | auto-mode 分類器、明示的な `ask` |
| 主要な更新操作 | `managed.rules` の `prompt` | `settings.json` の `ask` |
| `git add` | 既存の `prompt` を維持 | 専用の `ask` なし |
| 許可済みの操作 | 通常はそのまま進み、毎回自動審査されるわけではない | sandbox 内の Bash は原則 auto-allow。content-scoped `ask` 等は別途適用 |

Codex の `prompt` は自動 reviewer に回り得る。Claude の content-scoped `ask` は、一致するコマンド形で人へ確認する。どちらも任意の呼び出し経路を網羅する境界とはみなさない。Codex の設定の正本は `scripts/codex-config/policy.toml` で、本変更では reviewer・モデル・feature 設定を変更しない。調査時の保存値は `guardian_subagent`、当該セッションの実効 reviewer は `auto_review` だったため、運用時は実効設定も確認する。

主要な更新操作は `git commit` / `git push` / `chezmoi apply`、`gh pr` の create / edit / merge / close / reopen / comment / review / ready / lock / unlock、`gh issue` の create / edit / close / reopen / comment / delete / lock / unlock を対象とする。Codex の既存 `git add` も維持する。`gh api` は GET を含めて審査・確認の対象にする。HTTP method や payload を prefix だけで安全に分類しようとせず、読み取り API で審査が増える副作用を受け入れる。`chezmoi apply --dry-run` も同じ prefix に一致する。

これは主要なコマンド形を補う一覧で、共有更新の全経路を列挙したものではない。`git -C ... push`、`chezmoi --source ... apply`、絶対パスや任意スクリプト経由、MCP / app は同じ prefix に一致するとは限らない。会話上の合意原則はこれらにも適用する。

Claude の `npm run` / `yarn run` / `cargo run` の広い `allow` は削除する。sandbox 内の通常実行は引き続き可能で、sandbox 外の実行は既存の許可や他の判定条件に該当しなければ分類器へ回す。任意コード実行を禁止したわけではなく、残している build / test 許可も無害性を保証しない。無効化済み plugin の `Skill(commit-commands:commit-push-pr)` allow も削除する。独自の classifier policy や新しい承認 hook は導入しない。

通知を伴う Atlassian MCP 操作には `mcp__claude_ai_Atlassian_Rovo__create*` / `mcp__claude_ai_Atlassian_Rovo__transition*` / `mcp__claude_ai_Atlassian_Rovo__addCommentToJiraIssue` の明示的な `ask` を追加する。これらは会話上の合意を置き換えず、Confluence update / Jira edit を無条件で許可する意味でもない。PR #438 は 2.1.310 の wildcard 解釈を静的に確認したが、実 write による承認 UI は未検証。source verifier は required entries の保持を検査し、runtime の prompt 発生を証明しない。

## command 除外の整理

`excludedCommands` は `[]` にする。PR #438 が 2.1.310 で確認した照合規則では裸名は完全一致で、従来の3件は引数付き実行に効かなかった。過去版やこの統合作業環境での再実測とは区別する。`gh *` は write / extension まで sandbox 外へ広げるため採用しない。狭い閲覧系 prefix も安全な適用範囲の実測・negative tests がないため今回は追加せず、必要時の通常の承認付き retry を維持する。除外が一致した場合に外れるのは OS の filesystem / network sandbox であり、通常の permission flow ではない。明示的な ask は残り、read-only 判定や allow rule で許可される場合を除いて分類器が評価するため、全 call が分類器に回る保証でもない。詳細は [ADR 0002](adr/0002-claude-code-sandbox-gh-investigation.md)。

## 例外の棚卸し

以下は2026-10-27に確認した管理設定であり、今回の整理では維持する。用途の候補と、必要性を実測した事実は区別する。

| 維持する設定 | 想定用途・次に確認する事項 |
|---|---|
| Claude `allowAllUnixSockets: true` | SSH agent 等との接続。Docker daemon に到達できても完全な隔離ではない。全 socket を許可する必要があるか、限定できるかは未検証 |
| Claude `allowLocalBinding: true` | ローカル開発サーバー。必要な実行経路と OS 差は未検証 |
| Claude `enableWeakerNestedSandbox: true` | nested sandbox の互換性。必要な環境と保護への影響は未検証 |
| Claude `allowUnsandboxedCommands: true` | sandbox で動かないツールの retry。許可ルールが retry にも適用される点を含め、必要性を再確認する |
| Claude の追加 write 領域 | `/tmp`、Codex plugin data、agmsg の db / teams / run、SSH known_hosts。各用途と最小範囲を再確認する |
| Claude の追加 read 領域 | SSH config / config.local / known_hosts、OrbStack SSH config。秘密鍵の許可とは区別し、deny と併せて必要性を確認する |
| Codex の追加 `writable_roots` | machine-local の free 設定。調査端末は agmsg の db / teams / run。端末ごとに再確認する |

Claude の credential 系 `Read` / `Edit` deny は維持する。Codex の workspace 外への書き込み制限は、機密ファイルの読み取り拒否と同じではない。Codex の秘密情報読み取り保護の設計は未解決事項として残す。Claude の Bash sandbox は file tools・MCP server・hook の隔離を保証しない。

## 管理外 default.rules の清掃案

`~/.codex/rules/default.rules` は Codex が保存する machine-local の許可で、chezmoi は所有・削除しない。調査端末では2026-10-27時点で63件、すべて `allow` だった。`codex` 全般、`git tag`、過去の個別コマンド、一部の `rm`、`/tmp` の Bash スクリプトへの許可を含む。端末ごとに内容を確認し、コマンドに含まれる非公開情報を共有文書や Git にコピーしない。

提案は全件を退避して空に戻し、自動審査を既定として、必要な恒久例外だけを後から検討すること。清掃すると従来通過していた操作の審査が増え得る。この文書の追加や管理元の変更だけで、清掃を実行しない。

別途清掃を承認する際は、次の手順を具体化する。

1. Codex による同時更新を避ける時間を確保し、対象端末・絶対パス・型・mode・SHA-256・symlink の有無と宛先を記録する。
2. Git 管理外の0700ディレクトリに、内容・mode・symlink の状態を復元できるバックアップを作る。symlink なら参照先も確認し、その書き換え範囲を承認対象に含める。
3. 審査対象の内容とバックアップを確認し、空のルールファイルへの変更を明示承認する。直前に状態を再確認し、変化があれば再レビューする。
4. 対象だけを変更し、read-back と新規セッションでの有効性を確認する。実際の push / commit / apply を試験として無断実行しない。
5. 問題があれば対象の元の内容・mode・symlink 状態を復元し、read-back する。確認できない場合は復元済みと報告しない。

## 検証と配置

管理元では JSON/TOML の parse、Claude の permission verifier と negative tests、`codex execpolicy check` を使う既存 Bats を実行する。execpolicy check は候補コマンドを実行せず判定だけを確認する。主要更新操作が `prompt`、`git status` / `gh pr view` 等が新たな `prompt` に巻き込まれないことと、重なる `allow` より `prompt` が優先されることを確認する。Bats を変更した場合は `bats tests/bats/` 全体を実行し、skip / 失敗を含めて報告する。

Fugu は `AGENTS.md` と `rules/managed.rules` を通常版への symlink で共有するため、通常版への配置は Fugu にも影響する。利用可能なら専用 CLI でも隔離 fixture の同じ execpolicy 判定を確認する。Fugu の自動審査は Sakana API 側を使う構成であり、通常版と同じ審査モデル・結果とはみなさない。静的なルール判定は API による自動審査や承認 UI の実動確認を代替しない。Fugu の構成詳細は [Codex 設定](codex.md) を参照。

live apply は [AGENTS.md の Chezmoi Operations](../AGENTS.md#chezmoi-operations) に従う。source の絶対パス・HEAD・manifest と対象パスを確定し、raw diff と評価対象をレビューしてから target-scoped diff / dry-run を確認する。既存 target の内容・mode・symlink をバックアップし、対象と操作の明示承認後にのみ反映する。worktree では source を常に明示し、script 実行は別途承認がなければ除外する。直前の manifest 再比較で変化があれば停止する。

配置後は対象の read-back と選択 source との差分を確認し、実効設定は新規セッションで確認する。`managed.rules` の復元は共有元1ファイルを戻すことで通常版と Fugu の両方に作用する。指示文・Claude settings はそれぞれのバックアップから戻す。管理外 `default.rules` の清掃・復元は独立した作業として扱い、検証状態を維持したか復元したかまで報告する。

## 公式資料

- [Codex Auto-review](https://learn.chatgpt.com/docs/sandboxing/auto-review)
- [Codex Rules](https://learn.chatgpt.com/docs/agent-configuration/rules)
- [Claude Code permissions](https://code.claude.com/docs/en/permissions)
- [Claude Code sandbox](https://code.claude.com/docs/en/sandboxing)
