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

### 初回 smoke

agmsg の team はリポジトリごとに分ける。別 repo の依頼や履歴と混ざるのを
避けるため、この repo では team 名を `dotfiles` にする。
agent 名は通常 `cc` / `codex` にする。Codex はレビュー専用ではなく
メイン作業セッションにもなるため、`codex-reviewer` のような固定責務名は
必要になった時だけ一時 role として使う。

配信 mode は repo の Codex hook 管理方針で分ける:

- この dotfiles repo、または `.codex/hooks.json` を Git 管理している repo:
  Codex は `off` にして手動受信 (`$agmsg`) にする。`turn` は Codex hook
  設定を書き換えるため、作業ツリーを汚す可能性がある
- `.codex/hooks.json` を Git 管理していない repo:
  Codex は `turn` にする。Codex は `both` をサポートしないため使わない
- Codex `monitor` は beta / PATH shim 依存なので通常は使わない
- Claude Code 側は `turn` か `both` を使う。`both` は monitor push と
  turn pull の両経路で同一 message が見えることがある

Claude Code 側:

```text
/agmsg
/agmsg mode both
```

team は `dotfiles`、role は `cc` を使う。

Codex 側:

```text
$agmsg
$agmsg mode off
```

team は `dotfiles`、role は `codex` を使う。
最後に `cc` から `codex` へ短い message を送り、Codex 側で `$agmsg`
を実行して受信できることを確認する。その後 `codex` から `cc` へ返信し、
Claude Code 側で自動受信できることを確認する。

### 設定の保存先

agmsg の install 本体は `~/.agents/skills/agmsg/` に置かれる。team 登録は
repo ごとの runtime state で、`~/.agents/skills/agmsg/teams/<team>/config.json`
に保存される。このファイルには agent 名、agent type、project path が入る。

message 本体は `~/.agents/skills/agmsg/db/messages.db` に保存される。どちらも
chezmoi 管理対象ではなく、agmsg installer/runtime が管理する local state として扱う。

### 使い方例

agmsg を使う前に、依頼元・依頼先の両方のセッションで同じ repo 用 team に
join しておく。この repo では `dotfiles` team を使う。別 repo では、その repo
専用の team を作る。

Claude Code から Codex に軽いレビューを依頼する例:

```text
/agmsg send codex "repo: /Users/toku345/.local/share/chezmoi
branch: feat/agmsg-handoff-setup
base: origin/main
目的: docs/claude-code-plugins.md の agmsg 使い方追記をレビューしてください。
非対象: 実装修正、PR 操作、agmsg installer の変更。
確認: typo、手順の不足、repo ごとに team が必要な旨が伝わるか。
1 回実行して、DONE または blocked を返してください。"
```

Codex から Claude Code に結果だけ返す例:

```text
$agmsg send cc "DONE: docs の使い方例を確認しました。
気になる点: 長文依頼は agmsg 本文ではなく /tmp 配下の request.md を渡す運用が
もう少し目立つとよさそうです。
追加変更はしていません。"
```

長い handoff は本文を直接送らず、ファイルに置いて path を送る:

```sh
mkdir -p /tmp/agmsg-handoff-dotfiles-docs
$EDITOR /tmp/agmsg-handoff-dotfiles-docs/request.md
```

```text
/agmsg send codex "handoff request:
/tmp/agmsg-handoff-dotfiles-docs/request.md

repo: /Users/toku345/.local/share/chezmoi
team: dotfiles
1 回実行して、result を /tmp/agmsg-handoff-dotfiles-docs/result.md に書き、
DONE または blocked を返してください。"
```

### 運用ルール

- 長文依頼やレビュー結果は `/tmp/agmsg-handoff-<slug>/request.md`
  / `result.md` に置き、agmsg では path を送る
- secret、credential、長大 diff 本文は agmsg に送らない
- 依頼文には「1 回実行して DONE/blocked を返す」を入れ、自動往復ループを作らない
- Codex monitor beta / PATH shim は通常使わない

### 更新

agmsg は automatic latest 追従しない。更新時は
`.chezmoiscripts/run_after_setup-agmsg.sh` の `AGMSG_REF` をレビュー付きで
新しい full commit SHA に bump し、`chezmoi apply -v` で installer の
`--update` path を走らせる。

## 定期更新チェックリスト

agmsg / cc-session-finder / Claude Code plugins は自動更新しない
(`DISABLE_AUTOUPDATER=1` と marketplace の `autoUpdate=false` は維持)。
四半期に 1 回を下限として、同じレビュー窓で更新有無を確認する。変更と
rollback を分離するため、実際の bump はコンポーネントごとに reviewed PR を
作る。レビュー窓は [docs/security.md の high-privilege CLI 四半期 pin
レビュー](security.md#high-privilege-clis-and-casks) に相乗りし、upstream の
動きが速くなったら月次に短縮してよい。

### agmsg

[§更新](#更新) の手順に従う (upstream diff レビュー → `AGMSG_REF` bump →
`chezmoi apply -v` → `/agmsg version` で反映確認)。

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
