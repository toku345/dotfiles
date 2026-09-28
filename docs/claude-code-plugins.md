# Claude Code プラグイン / agent messaging セットアップ

`chezmoi apply` では Claude Code のプラグインは自動インストールされません。新しいマシンや環境では手動セットアップが必要です。

`chezmoi apply` 実行時にプラグインが未インストールの場合、注意メッセージが表示されます。

## agmsg

Claude Code / Codex / 別セッション間の handoff transport。
`chezmoi apply` の `.chezmoiscripts/run_after_setup-agmsg.sh` が
`~/.agents/skills/agmsg/` に pin 済み commit の agmsg を導入・更新する。

### 用途

- Claude Code から Codex へレビュー・調査依頼を送る
- Codex から Claude Code へ follow-up や review 結果を返す
- 別セッションへの handoff prompt を手動 copy & paste せず共有する

agmsg はレビュー gate そのものではない。`$pr-review` / `/pr-review`
の base pinning / fail-closed aggregation は既存 gate 側で維持する。

### 手動運用

独立した別セッションへの通信は、agmsg・Claude 標準通信ともユーザーの明示依頼時だけ行う。
現在のタスク配下のサブエージェント通信は対象外とする。

- Claude Code / Codex とも配信モードは `off` を維持する。
- team と送受信者名をユーザーが明示する。この repo の既存登録は `dotfiles` team の `cc` / `codex` だが、同じ repo で起動しただけではその名前を自動使用しない。
- 自動参加・監視開始・自動返信は行わない。未参加なら、参加先と agent 名を確認してから公式 `join.sh` で登録し、配信は `off` のまま使う。
- 同じ agent 名を複数セッションで使う場合、手動受信先を分離する保証はない。

引数なしの `/agmsg` / `$agmsg` は identity 解決や inbox 読み取りを伴うため、停止確認には使わない。
送受信は後述の公式スクリプトで対象を明示する。`inbox.sh` は表示したメッセージを既読にする。

### この repo の自動配信を停止する

実環境への反映承認後、project-local 設定を日時付きでバックアップし、repo root で実行する:

```bash
bash ~/.agents/skills/agmsg/scripts/delivery.sh set off claude-code "$PWD"
bash ~/.agents/skills/agmsg/scripts/delivery.sh status claude-code "$PWD"
bash ~/.agents/skills/agmsg/scripts/delivery.sh status codex "$PWD"
```

Claude 側の agmsg フックだけを除去し、他の設定は保持する。
Codex は既に `off` のため、Git 管理の検証用フックを書き換えない。
`delivery.sh stop` は全 watcher が対象になるため、この停止作業では使わない。

`set off` は watcher 停止失敗を無視し、状態表示は pidfile に依存する。
終了コードや `off` 表示だけで完了とせず、プロセスを確認できる環境で、
この project path と agent type に一致する watcher の不在を確認する。
残っていれば対象を限定して停止し、Claude 側の Monitor task は所有セッションでも確認する。
確認権限が不足する場合は停止確認を未完了として報告する。
変更前から動いている対象セッションは再起動し、通常作業で自動受信や agmsg フック出力がないことを確認する。
他 repo・他マシンで agmsg に参加したことがある場合は、`teams/<team>/config.json` の project path ごとに
`delivery.sh status` を実行し、`off` でなければ同じ手順で停止する。

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

### 設定の保存先

agmsg の install 本体は `~/.agents/skills/agmsg/` に置かれる。team 登録は
repo ごとの runtime state で、`~/.agents/skills/agmsg/teams/<team>/config.json`
に保存される。このファイルには agent 名、agent type、project path が入る。

message 本体は `~/.agents/skills/agmsg/db/messages.db` に保存される。どちらも
chezmoi 管理対象ではなく、agmsg installer/runtime が管理する local state として扱う。

### 使い方例

ユーザーが `dotfiles` team の `cc` から `codex` への送信を指定した場合:

```bash
bash ~/.agents/skills/agmsg/scripts/send.sh dotfiles cc codex \
  'repo の調査依頼: /tmp/agmsg-handoff-dotfiles/request.md'
```

受信側でもユーザーが `dotfiles` / `codex` の手動受信を指定した場合:

```bash
bash ~/.agents/skills/agmsg/scripts/inbox.sh dotfiles codex
```

返信は別途ユーザーが明示した場合だけ送信する。既存の実セッション宛てに動作確認用メッセージを送らない。

### 運用ルール

- 長文依頼やレビュー結果は `/tmp/agmsg-handoff-<slug>/request.md` / `result.md` に置き、agmsg では path を送る
- secret、credential、長大 diff 本文は agmsg に送らない
- 依頼文には repo path、branch/base、目的、非対象、検証方法と「1 回実行して結果を artifact に保存する」を含める
- 通信テストは一時ディレクトリに scripts をコピーし、空の team・DB・run を使う。`AGMSG_STORAGE_PATH` だけでは team 登録を隔離できないため、実インストールの `join.sh` で検証用登録を作らない
- 通常起動での受信拒否と `accept` 指定時の受信確認は専用 Claude セッションで行い、未実施なら未検証として記録する

### 更新

現行 pin は `AGMSG_REF` を正とする。次回更新は [Issue #376](https://github.com/toku345/dotfiles/issues/376) で扱う。

agmsg は automatic latest 追従しない。更新時は
`.chezmoiscripts/run_after_setup-agmsg.sh` の `AGMSG_REF` をレビュー付きで
新しい CLI 正式リリースタグ (`vX.Y.Z`) が指す full commit SHA に bump し、
`chezmoi apply -v` で installer の `--update` path を走らせる。未リリースの
`main` 先端は pin しない。GitHub の latest release は `app-vX.Y.Z` を返す場合が
あるため、CLI の更新候補は `vX.Y.Z` タグ一覧から選び、タグと commit SHA の
対応を確認してから差分をレビューする。

## 定期更新チェックリスト

agmsg / cc-session-finder / Claude Code plugins は自動更新しない
(`DISABLE_AUTOUPDATER=1` と marketplace の `autoUpdate=false` は維持)。
四半期に 1 回を下限として、同じレビュー窓で更新有無を確認する。変更と
rollback を分離するため、実際の bump はコンポーネントごとに reviewed PR を
作る。レビュー窓は [docs/security.md の high-privilege CLI 四半期 pin
レビュー](security.md#high-privilege-clis-and-casks) に相乗りし、upstream の
動きが速くなったら月次に短縮してよい。

### agmsg

[§更新](#更新) の手順に従う (CLI の `vX.Y.Z` タグ選定 → タグが指す full SHA
までの upstream diff レビュー → `AGMSG_REF` bump → `chezmoi apply -v` →
Claude Code は `/agmsg version`、Codex は
`~/.agents/skills/agmsg/scripts/version.sh` で同じタグが返ることを確認)。

### cc-session-finder

1. candidate の full commit SHA を先に確定し、現行 pin との差分をレビュー:
   `https://github.com/jugyo/cc-session-finder/compare/<現行 SHA>...<candidate SHA>`
2. `.chezmoiscripts/run_after_setup-cc-session-finder-mcp.sh` の
   `CC_SESSION_FINDER_REF` を、レビューした同じ candidate SHA に bump する
3. merge 前に、一時 install root で candidate が実際に build・起動できることを
   確認する (`<candidate SHA>` は手順 1 と同じ値):

   ```sh
   candidate=FULL_40_CHARACTER_SHA
   tmpdir=$(mktemp -d)
   trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM
   cargo install --git https://github.com/jugyo/cc-session-finder.git \
     --rev "$candidate" --locked --root "$tmpdir" --bin cc-session-finder
   "$tmpdir/bin/cc-session-finder" --version
   ```

4. PR をレビュー・merge した後、main source directory を merged main へ同期する。
   `<candidate SHA>` を手順 1 と同じ値にして、local source の pin も確認する:

   ```sh
   cd ~/.local/share/chezmoi
   git switch main
   git pull --ff-only
   candidate=FULL_40_CHARACTER_SHA
   actual=$(sed -n 's/^CC_SESSION_FINDER_REF="\([^"]*\)"/\1/p' \
     .chezmoiscripts/run_after_setup-cc-session-finder-mcp.sh)
   test "$actual" = "$candidate"
   ```

5. main source directory で明示的に再導入する:
   `CC_SESSION_FINDER_REINSTALL=1 chezmoi apply -v`。このときだけ managed binary
   (`${CARGO_INSTALL_ROOT:-${CARGO_HOME:-$HOME/.cargo}}/bin/cc-session-finder`)
   へ `cargo install --force --locked --rev <REF>` する。通常の
   `chezmoi apply` は既存 binary の revision を判定せず、自動更新しない
6. install 成功ログを確認し、実際に登録する managed binary を smoke test する:

   ```sh
   managed_binary="${CARGO_INSTALL_ROOT:-${CARGO_HOME:-$HOME/.cargo}}/bin/cc-session-finder"
   "$managed_binary" --version
   ```

   version 出力は semver のみで commit SHA を証明しない
7. MCP 登録確認: `claude mcp get cc-session-finder` /
   `codex mcp get cc-session-finder`
   (command path が `$managed_binary` と一致することも確認)
8. 稼働中の MCP server プロセスは旧バイナリのまま動き続けるため、Claude Code /
   Codex のセッションを再起動して新バイナリに切り替える

セットアップの全体像 (MCP 登録の仕組み) は
[docs/codex.md の cc-session-finder MCP](codex.md#cc-session-finder-mcp) を参照。

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
- `bats tests/bats/test_agmsg_setup.bats tests/bats/test_cc_session_finder_mcp_setup.bats`
- cc-session-finder bump の merge 前は、一時 install root で candidate SHA の
  `cargo install --locked` と managed binary の smoke test が成功する
- cc-session-finder bump の merge 後は
  `CC_SESSION_FINDER_REINSTALL=1 chezmoi apply -v` がエラーなく完了する
- `claude mcp get cc-session-finder` / `codex mcp get cc-session-finder` で
  managed binary が登録されている

## codex-plugin-cc

Codex CLI を Claude Code 内から呼び出すための OpenAI 公式プラグイン。

### 用途

- `/codex:adversarial-review` — 設計前提・実装判断への adversarial コードレビュー
- `/codex:rescue` — 調査・修正・長時間タスクを Codex に委譲
- `/codex:setup` — Codex CLI の準備状態を確認

実装計画レビューは `codex exec` コマンドを直接使用する（`CLAUDE.md` の「Codex の使い分け」セクション参照）。

### 前提条件

- Node.js >= 18.18
- Codex CLI (`npm install -g @openai/codex`)
- ChatGPT サブスクリプションまたは OpenAI API キー

### インストール手順

Claude Code 内で以下を実行:

```text
/plugin marketplace add openai/codex-plugin-cc
/plugin install codex@openai-codex
/reload-plugins
/codex:setup
```

### 既知の問題

- `/codex:setup` の内部で実行される認証チェック（`codex-companion.mjs setup`）が Claude Code の sandbox 内で失敗する（macOS `system-configuration` へのアクセス制限）。`codex` は `settings.json` の `excludedCommands` に含まれているが、`excludedCommands` では Mach service 制限を回避できないため、`dangerouslyDisableSandbox: true` が必要となる。AI が sandbox 回避を自動判断するため、ユーザー側の追加操作は不要だが、権限確認のプロンプトが表示される場合がある。
