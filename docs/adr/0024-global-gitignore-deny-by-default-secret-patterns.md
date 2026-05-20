# ADR 0024: Global gitignore deny-by-default for bare-name secret patterns

## Status

Accepted (2026-05-20).

## Context

ADR 0001 "Empirical baseline coverage snapshot" で確立した通り、Anthropic baseline の bare-name `permissions.deny` カバレッジは shell config 系 (`.bashrc` / `.gitconfig` 等) に限定され、secret pattern (`.env` / `id_*` / `*.key` 等) は対象外。PR #216 (2026-05-19 merged) で `permissions.deny` への bare-name secret pattern 追加が char-special pollution と `chezmoi apply` 失敗を引き起こすことが empirical に確認され、`permissions.deny` での補完は禁止された。

並行して PR #216 verification で、Claude Code session 中の `cd` 失敗 → cwd fallback による stray secret ファイル生成 (`.env` / `id_ed25519` / `foo.key` / `control.txt`) が実観測された。この session leakage は chezmoi 非依存で、任意の repo の cwd で発生しうる。

## Decision

`~/.config/git/ignore` を chezmoi 管理化 (`private_dot_config/git/ignore`) し、bare-name secret patterns を deny-by-default で追加する。対象 patterns は `.env` / `.env.*` / `.envrc` / `.netrc` / `.npmrc` / `id_ed25519` / `id_ed25519.*` / `id_rsa` / `id_rsa.*` / `*.key` / `*.pem`。

`.env.*` は `.env.example` 等の非 secret も glob で巻き込むが、これは意図的な許容範囲とする (Issue #220 の YAGNI 方針)。同様に `.envrc` (direnv) や `.npmrc` (public registry config) のような **非 secret でも commit されうる標準設定** も deny-by-default に含む。false negative (公開 setting が ignore される) より false positive (誤って commit してしまう) のコストが大きいとの判断。

例外運用は明示的な opt-in を要求する:

- 一時例外 (単発 fixture commit): `git add -f <path>`
- 恒常例外 (repo 固有の方針): repo-local `.gitignore` に **narrow negate** (例: `!tests/fixtures/*.key`) を追記し、理由をコメントで残す。`!*.key` のような broad negate は事故源になりやすいため避ける

## Consequences

本 dotfiles を apply した環境で、**untracked な secret-like file の accidental staging** を抑止する。Anthropic baseline → `permissions.deny` (絶対パス限定) → global gitignore の三層 onion model が完成し、secret leakage 対策の全体像が明確化される。

**保護範囲外** (誤解防止のため明示):

- 既に tracked になっている secret file (history 残存リスクは別途対処要)
- `git add -f` で明示的に bypass された場合
- 本 dotfiles 未 apply の環境 (CI / 他コラボレーターのマシン)

トレードオフとして、OSS contribution で fixture key (`tests/fixtures/server.key` 等) を扱う場合に `git add -f` または repo-local narrow negate (`!tests/fixtures/*.key`) が必要になる。incident cost (history 残存 → revoke/rotation) は friction cost (数秒の opt-in) を上回ると判断する。

副作用: chezmoi source root の `.envrc` は global gitignore 経由で守られるため、source root `.gitignore` への追加 patterns は不要。

## Considered alternatives

- **source root `.gitignore` のみ** — chezmoi 固有事情への対処として scope はタイトだが、他 repo (work / OSS) が無防備のまま。session leakage が chezmoi 非依存である事実と整合しない
- **Hybrid (global + source root の二重管理)** — `*.key` / `*.pem` のみ source root に置く案。論理は通るが、二重管理で参照系統が複雑化し、将来の保守者が「なぜ二重?」と疑問を持つコストに見合わない

## Related

- [ADR 0001](0001-claude-code-sandbox-git-least-privilege.md) — Empirical baseline coverage snapshot
- [Issue #220](https://github.com/toku345/dotfiles/issues/220)
- [PR #216](https://github.com/toku345/dotfiles/pull/216) — `permissions.deny` bare-name removal incident
