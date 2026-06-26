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

Claude Code 側:

```text
/agmsg
/agmsg mode monitor
```

team は `dotfiles`、role は `cc-lead` を使う。

Codex 側:

```text
$agmsg
$agmsg mode turn
```

team は `dotfiles`、role は `codex-reviewer` を使う。
最後に `cc-lead` から `codex-reviewer` へ短い message を送り、
Codex 側で `$agmsg` または次 turn で受信できることを確認する。

### 設定の保存先

agmsg の install 本体は `~/.agents/skills/agmsg/` に置かれる。team 登録は
repo ごとの runtime state で、`~/.agents/skills/agmsg/teams/<team>/config.json`
に保存される。このファイルには agent 名、agent type、project path が入る。

message 本体は `~/.agents/skills/agmsg/db/messages.db` に保存される。どちらも
chezmoi 管理対象ではなく、agmsg installer/runtime が管理する local state として扱う。

### 運用ルール

- 長文依頼やレビュー結果は `/tmp/agmsg-handoff-<slug>/request.md`
  / `result.md` に置き、agmsg では path を送る
- secret、credential、長大 diff 本文は agmsg に送らない
- 依頼文には「1 回実行して DONE/blocked を返す」を入れ、自動往復ループを作らない
- Codex monitor beta / PATH shim は v1 では使わない。Codex は `turn` mode に留める

### 更新

agmsg は automatic latest 追従しない。更新時は
`.chezmoiscripts/run_after_setup-agmsg.sh` の `AGMSG_REF` をレビュー付きで
新しい full commit SHA に bump し、`chezmoi apply -v` で installer の
`--update` path を走らせる。

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
