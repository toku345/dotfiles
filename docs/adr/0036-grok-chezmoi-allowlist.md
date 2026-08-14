# ADR 0036: Manage Grok Build with a chezmoi allowlist

## Status

Accepted (2026-08-14)

## Context

`~/.grok` is not a settings directory. It mixes user-authored files with installer binaries, marketplace caches, session transcripts, worktrees, and secrets (`auth.json`, `mcp_credentials.json`). Managing the tree as a whole would commit runtime state and credentials.

live `~/.grok/config.toml` is written back by the TUI (`/settings`, `/theme`, `[hints]`) and by the installer (marketplace auto-install flags, `privacy_banner_acked`). Putting that file under chezmoi would make `chezmoi apply` revert those writes. That is the same force that led Codex to a separate baseline file in [ADR 0024](0024-codex-baseline-hash-state.md).

Grok also ships official managed layers (`managed_config.toml`, `requirements.toml`). Docs say Grok maintains the user-level `managed_config.toml` itself, so that path is not a safe chezmoi target. `requirements.toml` is an org lock layer, not a place for personal preference.

Claude compatibility is on by default. `grok inspect` already loads `~/.claude/CLAUDE.md`, `~/.claude/skills`, hooks, and MCP servers. Codex compatibility cells for `agents` / `rules` are inert, so `~/.codex/AGENTS.md` does not reach Grok.

The first durable Grok-specific need is commit attribution: Grok-authored commits should end with `AI-Assisted-By: Grok Build (<model-id>)`. That instruction must live in a Grok-native home file, not in repo `AGENTS.md` or `~/.claude/CLAUDE.md`, or Claude-authored commits would pick up a Grok trailer.

## Decision

Manage `~/.grok` with a selective allowlist under `private_dot_grok/`. Do not manage live `config.toml`. Do not copy the Codex 3-file hash gate yet.

Allowlist (add a path only when the durable file exists):

- `private_dot_grok/AGENTS.md` → `~/.grok/AGENTS.md`
- later, if authored: `skills/`, `hooks/`, `agents/`, `workflows/`, `rules/`, and a secret-free `lsp.json`

Denylist includes `config.toml`, `pager.toml`, `managed_config.toml`, `requirements.toml`, `auth.json`, `mcp_credentials.json`, `trusted_folders.toml`, sessions/logs/memory, bundled/bin/downloads/docs/completions, marketplace-cache, worktrees, and other runtime state. Never run `chezmoi add ~/.grok` on the directory.

Keep `[compat.claude]` at the product default. Shared skills, hooks, and MCP stay in `private_dot_claude/`. Put only Grok-specific instructions under `private_dot_grok/`.

Project-local `.grok/` in this repository is out of scope until a Grok-native project hook or workflow exists. Existing `.claude/hooks` and `.claude/rules` already load in Grok through Claude compatibility.

Commit attribution lives only in `~/.grok/AGENTS.md`, in this form:

```
AI-Assisted-By: Grok Build (<model-id>)
```

`<model-id>` is the current session's model identifier. Do not infer it from config or a prior session. Keep non-Grok trailers. Replace a stale Grok trailer instead of appending a second one. This trailer wins over repository commit conventions. Do not use `Co-authored-by` for Grok.

If later we need durable `config.toml` keys to propagate across machines, revisit a Codex-style baseline then. Do not `chezmoi add ~/.grok/config.toml` as the first choice.

## Consequences

### Positive

- `chezmoi apply` cannot wipe TUI or installer writes in `config.toml`
- secrets and session caches stay out of git
- Grok commit trailers do not leak into Claude sessions
- shared Claude assets keep working without duplication

### Negative

- a new machine does not restore theme / `permission_mode` / other TUI prefs
- trailer enforcement is instruction-only; a model can omit it (same as Codex)

### Risks

- a later `chezmoi add ~/.grok` would import cache and secrets; `docs/grok.md` forbids that
- writing the same trailer into `~/.claude/CLAUDE.md` or repo `AGENTS.md` would mis-attribute Claude commits
