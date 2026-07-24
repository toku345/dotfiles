# Codex 設定の管理方針

このリポジトリでは `~/.codex` を丸ごと管理しない。

設計判断 (3-file 構成 / hash gate / migration fail-closed) の詳細は [ADR 0024](adr/0024-codex-baseline-hash-state.md) を参照。

## 管理するもの

- `private_dot_codex/AGENTS.md` -> `~/.codex/AGENTS.md`
- `private_dot_codex/private_config.chezmoi.toml` -> `~/.codex/config.chezmoi.toml`
- `private_dot_codex/private_review.config.toml` -> `~/.codex/review.config.toml`
- `private_dot_codex/private_review_deep.config.toml` -> `~/.codex/review_deep.config.toml`
- `private_dot_codex/private_review_audit.config.toml` -> `~/.codex/review_audit.config.toml`
- `private_dot_codex/rules/managed.rules` -> `~/.codex/rules/managed.rules`
- `.chezmoiscripts/run_after_check-codex-config.sh`
- `.chezmoiscripts/run_after_setup-agmsg.sh`
- `.chezmoiscripts/run_after_setup-cc-session-finder-mcp.sh`

## 管理しないもの

- `~/.codex/auth.json`
- `~/.codex/history.jsonl`
- `~/.codex/sessions/`
- `~/.codex/state_*.sqlite`
- `~/.codex/logs_*.sqlite*`
- `~/.codex/cache/`
- `~/.codex/rules/default.rules` (Codex UI が更新する user-local allow rules)
- `~/.codex/.baseline-hash` (chezmoi script が生成する hash state)

## 運用

1. `chezmoi apply` で `~/.codex/config.chezmoi.toml` を配置する
2. `~/.codex/config.toml` が存在しない場合だけ、script が baseline をコピーして初期化する
3. 以後 `~/.codex/config.toml` は live file として残し、Codex が書いた local-only section を保持する
4. baseline を更新したら、`chezmoi apply` が baseline の hash 変化を検出して exit 1 で停止する。`diff -u ~/.codex/config.toml ~/.codex/config.chezmoi.toml` で baseline 更新分を確認し、local-only section を保ったまま live に取り込む。merge 後、新 baseline を ACK するため `hash=$(sha256sum ~/.codex/config.chezmoi.toml 2>/dev/null || shasum -a 256 ~/.codex/config.chezmoi.toml) && printf '%s\n' "${hash%% *}" > ~/.codex/.baseline-hash && chmod 600 ~/.codex/.baseline-hash` を実行し、再 `chezmoi apply` する。無関係な dotfile を急ぎ apply したい場合は `chezmoi apply <target>` で個別指定すればこの script は trigger されない

## local-only とする section

- `[projects."..."]`
- `[mcp_servers.*]`
- `[notice.*]`
- `[plugins.*]`
- `[marketplaces.*]`
- `[desktop]`

必要に応じて、ローカル provider や一時的な実験設定も `~/.codex/config.toml` 側にのみ置く。

## agmsg writable roots

agmsg installer は Codex bridge / monitor beta 用に、`~/.codex/config.toml`
の `[sandbox_workspace_write].writable_roots` へ以下の絶対パスを追加する:

- `~/.agents/skills/agmsg/db`
- `~/.agents/skills/agmsg/teams`
- `~/.agents/skills/agmsg/run`

この repo では Codex monitor beta を通常運用の対象外とし、Codex delivery
mode は `off` で使うが、agmsg runtime state の書き込み先として同じ
3ディレクトリを許可する。これらは
`~/.codex/config.chezmoi.toml` ではなく installer-managed local entry として
live config に保持する。baseline 更新時は他の local-only section と同様に残す。

`.chezmoiscripts/run_after_setup-agmsg.sh` は install/update 前後の
`~/.codex/config.toml` diff を確認し、この3ディレクトリの writable roots 追加
以外の変更が入った場合は fail loud する。

## cc-session-finder MCP

`.chezmoiscripts/run_after_setup-cc-session-finder-mcp.sh` は `cc-session-finder` を pinned revision で install し、Claude Code と Codex の両方に user-local MCP server として登録する。Codex 側は `~/.codex/config.toml` の `[mcp_servers.cc-session-finder]` に以下を保持する:

```toml
[mcp_servers.cc-session-finder]
command = "/absolute/path/to/cc-session-finder"
args = ["mcp"]
```

この section は `~/.codex/config.chezmoi.toml` ではなく installer-managed local entry として live config に保持する。baseline 更新時は他の local-only section と同様に残す。

managed install は `${CARGO_INSTALL_ROOT:-${CARGO_HOME:-$HOME/.cargo}}/bin/cc-session-finder` (CARGO_INSTALL_ROOT → CARGO_HOME → `~/.cargo` の順で解決) を優先する。通常の `chezmoi apply` は既存 binary の revision を判定せず、`CC_SESSION_FINDER_REINSTALL=1 chezmoi apply -v` のときだけ pinned revision を managed path へ強制再インストールする。`CC_SESSION_FINDER_REF` の reviewed bump 手順は [docs/claude-code-plugins.md の定期更新チェックリスト](claude-code-plugins.md#定期更新チェックリスト) を参照。

## rules

`~/.codex/rules/default.rules` は Codex の承認 UI が書き換えるため chezmoi 管理しない。安全側の上書きが必要なものだけ `~/.codex/rules/managed.rules` で管理する。Codex は複数 rule を merge し最も制限的な decision を採用するため、`default.rules` に広い `allow` が追加されても `managed.rules` の `prompt` で外部副作用や履歴作成を再確認できる。この most-restrictive-wins は Codex CLI 0.142.0 で確認済み（`requirements.toml` に `allow` を書くと "Codex merges these rules with other config and uses the most restrictive result (use 'prompt' or 'forbidden')" で拒否される）。再検証は `strings (command -v codex) | grep 'most restrictive result'`。

現在 `managed.rules` では以下を prompt に戻す。

- `gh api graphql`: query と mutation を prefix rule だけでは区別できないため
- `git add`: secret や無関係ファイルの staging を避けるため
- `git commit`: 履歴作成と commit trailer の確認を挟むため（prefix match のため `-m` / `-F` / `--amend` / editor 形を一律 prompt。ただし `git -C <path> commit` のように subcommand 前に flag が入る形は prefix 不一致で対象外）

## status line

Codex CLI の TUI footer は baseline で最小限の常時表示にする。

- `model-with-reasoning`
- `current-dir`
- `git-branch`
- `context-remaining`
- `five-hour-limit`
- `codex-version`

`used-tokens` は長時間セッションの診断には有用だが、常時表示ではノイズになりやすいため baseline には入れない。必要な時は `/status` または `/statusline` で確認する。

## review profile

通常の Codex session と `$pr-review` は `gpt-5.6-sol` を使う。レビュー用途では、直接 chezmoi 管理する独立 profile で reasoning effort だけを切り替える。

- `review.config.toml`: `gpt-5.6-sol` / `medium`
- `review_deep.config.toml`: `gpt-5.6-sol` / `high`
- `review_audit.config.toml`: `gpt-5.6-sol` / `xhigh`

これらの profile は `multi_agent` を有効にし、現在の model metadata が選ぶ V2 runtime で動作する。`approval_policy = "on-request"`、`sandbox_mode = "workspace-write"`、`sandbox_workspace_write.network_access = false`、`features.network_proxy = true` は managed baseline から継承し、review profile 側では上書きしない。`~/.codex/config.toml` の local-only section は持たず、`~/.codex/<profile>.config.toml` として直接管理するため、profile の更新は `config.chezmoi.toml` の hash gate 対象ではない。通常 session の baseline と `run_after_check-codex-config.sh` による live config 保護は従来どおり維持する。static verifier は checked-in の継承構造を固定し、Codex CLI が実際に layer した値は isolated smoke の turn context で確認する。

multi-agent version は session 開始時に固定されるため、既存 session 内で model や profile を切り替えず、新しい Codex process として起動する。`$pr-review` は実際に公開された tool schema を検査し、V1/V2 のどちらにも対応する。

V2 scheduler は canonical `FINAL_ANSWER` に加え、明示的な `completed` または「成功した full-tree snapshot で running を確認済みの task が後続 snapshot から退役した」という qualified retirement lifecycle evidence を要求する。退役が先行した場合は60秒以内に FINAL が届かなければ fail-closed とし、未観測taskの消失・error/interrupted・conflicting FINAL は許容しない。

```bash
codex exec --profile review -C <repo> '$pr-review --base <base>'
```

base を省略した auto-PR 経路では、`gh pr view` と fresh fetch をまず通常 sandbox で試す。sandbox/network policy や保護された `.git/FETCH_HEAD` に拒否された場合だけ、同一 command を approval 付きの scoped escalation で1回再試行する。profile 全体の network access や sandbox 権限は広げず、通常の Git/auth/ref error は昇格しない。offline または approval なしで実行する場合は immutable commit OID を `--base` に指定する。

checked-in の legacy V1 profile は置かない。V2 runtime に互換性問題が再発した場合は、次の one-shot command で `gpt-5.5` / V1 に退避する。

```bash
codex \
  -c 'features.multi_agent=true' \
  -c 'features.multi_agent_v2=false' \
  -c 'model_reasoning_effort="medium"' \
  exec --model gpt-5.5 \
  -C '<repo-root>' \
  '$pr-review --base <base>'
```

runtime smoke は credentials と server-side model catalog に依存するため CI ではなく手動で行う。merge 前は isolated `CODEX_HOME` と `/tmp` の fixture を使い、live config や chezmoi target を変更しない。`chezmoi apply` は変更を main に merge した後だけ実行する。

`model_reasoning_effort = "xhigh"` は監査には有用だが、通常の反復レビューでは過剰になりやすい。通常 session の baseline は `high` とし、review用途では profile を明示的に切り替える。

- `review`: 通常レビュー・dogfood iteration 用
- `review_deep`: 複雑な PR や main pre-merge review 用
- `review_audit`: security / release / cutover audit 用

`xhigh` の出力は自動修正キューではなく triage input として扱う。反復修正ループは通常 `medium` か `high` で 1-2 周に抑える。

## commit attribution

Codex CLI 0.131 系で `codex_git_commit` feature flag と `commit_attribution` config は削除された。baseline ではこれらの削除済み config は使わず、個人 preference として `~/.codex/AGENTS.md` に Co-authored-by trailer 指示を置く。

## 通知

macOS の desktop notification は今後の検討事項。`notify = [...]` は helper の存在や OS 差分に依存するため、baseline へ固定値として入れる前に template / opt-in / availability check の方針を決める。
