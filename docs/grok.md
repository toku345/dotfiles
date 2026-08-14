# Grok Build 設定の管理方針

このリポジトリでは `~/.grok` を丸ごと管理しない。

設計判断 (allowlist / live `config.toml` 非管理 / Claude 互換に共有アセットを任せる) の詳細は [ADR 0036](adr/0036-grok-chezmoi-allowlist.md) を参照。

## 管理するもの

- `private_dot_grok/AGENTS.md` -> `~/.grok/AGENTS.md`

後から user-authored の耐久ファイルができたときだけ、同じ `private_dot_grok/` 配下に足す。

- `~/.grok/skills/**` — Grok 固有 skill のみ。Claude と共有するなら `~/.claude/skills` のまま
- `~/.grok/hooks/**`
- `~/.grok/agents/**`
- `~/.grok/workflows/**`
- `~/.grok/rules/**`
- `~/.grok/lsp.json` — 中身に秘密が無いことを確認してから

## 管理しないもの

- `~/.grok/config.toml` (TUI / インストーラが書き戻す)
- `~/.grok/pager.toml`
- `~/.grok/managed_config.toml` (Grok が自動メンテする)
- `~/.grok/requirements.toml` (org lock 用)
- `~/.grok/auth.json`
- `~/.grok/mcp_credentials.json`
- `~/.grok/trusted_folders.toml`
- `~/.grok/sessions/`
- `~/.grok/logs/`
- `~/.grok/memory/`
- `~/.grok/bundled/`
- `~/.grok/bin/`
- `~/.grok/downloads/`
- `~/.grok/completions/`
- `~/.grok/docs/`
- `~/.grok/marketplace-cache/`
- `~/.grok/worktrees/`
- `~/.grok/worktrees.db`
- MCP `env` / `headers` に直書きした token

**`chezmoi add ~/.grok` でディレクトリごと取り込んではいけない。** cache と秘密が混入する。追加は常に `chezmoi add ~/.grok/<file-or-dir>` で allowlist の対象だけを指定する。

## 運用

1. 新規の Grok 固有ファイルは `chezmoi add ~/.grok/<path>` で取り込む (`private_` prefix は chezmoi が付与する)
2. live `~/.grok/config.toml` は chezmoi の source of truth にしない。TUI で変えた好みはマシンローカルのまま残る
3. 共有 skill / hook / MCP は `private_dot_claude/` 側を正とする。Grok はデフォルトの Claude 互換でそれを読む
4. このリポジトリの project-local `.grok/` は、Grok 固有の hook / workflow が必要になるまで作らない。既存の `.claude/hooks` と `.claude/rules` は Claude 互換で Grok からも見える

### apply 後の確認

`chezmoi apply` のあと、home の指示ファイルが載っていることを確認する:

```sh
grok inspect --json | python3 -c '
import json,sys
for item in json.load(sys.stdin).get("projectInstructions") or []:
    if item.get("path", "").endswith("/.grok/AGENTS.md"):
        print(item.get("scope"), item.get("path"))
        break
else:
    raise SystemExit("~/.grok/AGENTS.md not loaded")
'
```

`scope: global` と `~/.grok/AGENTS.md` が出ればよい。

## コミットトレーラー

Grok が書いたコミットは、本文と空行 1 つのあと、次の 1 行で終わる。

```
AI-Assisted-By: Grok Build (<model-id>)
```

例: `AI-Assisted-By: Grok Build (grok-4.6)`

- `<model-id>` は今のセッションの model id。config や前回セッションから推測しない
- 既存の非 Grok トレーラー (Codex の `Co-authored-by` など) は残す
- 古い / モデル違いの Grok トレーラーは置換し、二重に付けない
- 指示は `~/.grok/AGENTS.md` にだけ置く。repo 直下の `AGENTS.md` や `~/.claude/CLAUDE.md` には書かない
