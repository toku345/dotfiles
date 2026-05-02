---
name: chezmoi-target-resolver
description: >
  Resolve chezmoi source paths (private_*, dot_*, executable_*, *.tmpl)
  to target paths before invoking `chezmoi apply`, `chezmoi diff`, or
  `chezmoi cat` with a path argument. Use whenever you are about to run
  a chezmoi command on a specific file in a chezmoi source tree, or
  when the user gives you a source-style path to apply, diff, or cat.
  Skip if the path is already a target path (e.g. `~/.config/...`,
  `~/.zshrc`, etc.) or if no path argument is being passed.
---

# chezmoi-target-resolver

## Why this skill exists

`chezmoi apply <source-path>` fails with `<path> not managed`. chezmoi
accepts only **target paths** (the deployed location, like
`~/.config/fish/config.fish`) as positional arguments — never source
paths (like `private_dot_config/fish/config.fish`). Same for
`chezmoi diff` and `chezmoi cat`.

`chezmoi cat` is a partial exception: it accepts both, but the source
form is fragile across chezmoi versions. Always normalise to a target
path first.

This is the single most common chezmoi mistake. AGENTS.md documents it
under "Source-path gotcha".

## When this skill triggers

**Invocation model**: This skill is **auto-invoked** by Claude Code
when the description above matches the current task — there is no
slash command and no manual `Skill` call. The matcher fires when
Claude is about to run `chezmoi apply`, `chezmoi diff`, or
`chezmoi cat` with a path argument. To suppress this skill for a
specific request, tell Claude "skip the chezmoi-target-resolver
skill" or pass an already-resolved target path so the description
no longer matches.

**Hard gate (global-scope safety)**: This skill lives under
`~/.claude/skills/` (user-global) but only makes sense in a chezmoi
source tree. The first procedure step calls `chezmoi source-path`
and aborts otherwise — do **not** weaken that check. The skill must
be a no-op outside chezmoi-managed contexts so it never disturbs
non-chezmoi projects.

Trigger when about to run any of the following with a path argument:

- `chezmoi apply <path>`
- `chezmoi diff <path>`
- `chezmoi cat <path>`
- `chezmoi managed <path>`

Skip the skill when:

- Running `chezmoi apply` / `chezmoi diff` with no path (applies/diffs everything; that already works).
- Running `chezmoi edit <source>` (this command takes source paths).
- Running `chezmoi add <target>` (adding a new target file from $HOME).
- Not inside a chezmoi-managed source tree (see hard gate above).

## Procedure

1. **Check you're in a chezmoi source tree (or a worktree of it)**:
   `chezmoi source-path` alone only proves chezmoi is configured on the
   machine — it does not prove the cwd belongs to that source. As a
   user-global skill this would otherwise fire in arbitrary projects
   where chezmoi happens to be installed. Resolve the source root and
   gate on cwd descendancy, accepting git worktrees of the source.
   ```bash
   src_root=$(chezmoi source-path 2>/dev/null) || {
     echo "chezmoi not configured; skill is a no-op" >&2; exit 1
   }
   # `git rev-parse --git-common-dir` returns the common `.git` for
   # both the main checkout and any of its worktrees. dirname of that
   # is the main checkout's top-level. Compare to src_root via
   # realpath so symlinks and trailing slashes don't break the match.
   if git_common=$(git rev-parse --git-common-dir 2>/dev/null); then
     repo_root=$(realpath -- "$(dirname "$git_common")")
   else
     repo_root=$(realpath -- "$PWD")
   fi
   [[ "$repo_root" == "$(realpath -- "$src_root")" ]] || {
     echo "cwd is not inside chezmoi source tree ($src_root); skill is a no-op" >&2
     exit 1
   }
   ```
   If either check fails, abort the skill and tell the user this
   workflow only runs inside a chezmoi source tree (or a worktree of
   it) — they should cd accordingly.

2. **Classify the path** by inspecting it (no shell call needed for the
   common cases):

   | Path shape | Verdict |
   |---|---|
   | Begins with `private_`, `dot_`, `encrypted_`, `executable_`, `run_once_`, `run_onchange_` | Source path — resolve |
   | Ends in `.tmpl` | Source path — resolve |
   | Lives under `.chezmoiscripts/` | Source path — resolve |
   | Begins with `~/` or `/home/` or `/Users/<name>/` | Target path — use as-is |
   | Anything else | Run `chezmoi target-path <path>` and trust the result |

3. **Resolve** when classified as a source path:
   ```bash
   target=$(chezmoi target-path -- "$source") || {
     echo "chezmoi cannot resolve $source — is it managed?" >&2
     exit 1
   }
   ```

   - If `chezmoi target-path` exits non-zero, do **not** silently fall
     back to the source path. Report the error and stop. (`apply` would
     fail anyway, with a worse message.)
   - The `--` is intentional: source paths can begin with `-` after
     stripping a prefix.

4. **Run the chezmoi command** with the resolved target:
   ```bash
   chezmoi apply -- "$target"
   ```
   **Worktree prohibition (hard rule)**: `chezmoi apply` always
   reads from `~/.local/share/chezmoi/`, **not** the current git
   worktree. Do **not** run `chezmoi apply` from a git worktree —
   changes must be merged to main first. If `git rev-parse --git-dir`
   resolves under `.git/worktrees/`, refuse and tell the user to
   merge to main and `cd ~/.local/share/chezmoi` (or their main
   chezmoi source path) before applying. Same caveat applies to
   `chezmoi diff` when verifying intended deploys, since it would
   silently compare against main's source rather than the worktree.

## Worked examples

**Example 1**: User says "apply the new fish config".

```bash
src="private_dot_config/private_fish/config.fish"
tgt=$(chezmoi target-path -- "$src")        # → ~/.config/fish/config.fish
chezmoi apply -- "$tgt"
```

(Recursive chezmoi prefixes: `private_dot_config/private_fish/` deploys
to `~/.config/fish/`, with both directories getting mode 0700.)

**Example 2**: User says "diff this template".

```bash
src=".chezmoi.toml.tmpl"
tgt=$(chezmoi target-path -- "$src")        # → ~/.config/chezmoi/chezmoi.toml
chezmoi diff -- "$tgt"
```

**Example 3**: User passes `~/.config/ghostty/config`.

Already a target path. Use as-is — no resolution needed.

## Sandbox notes

`chezmoi` reads `~/.config/chezmoi/chezmoistate.boltdb` and so requires
`dangerouslyDisableSandbox: true` on Claude Code's macOS sandbox (see
AGENTS.md "Sandbox Gotchas"). When running these commands via Bash,
expect a sandbox prompt the first time.

## What to return to the caller

After running the resolved chezmoi command, report:

1. The original source path the user mentioned.
2. The resolved target path you used.
3. The exit status of the chezmoi command.

Do not mutate any files. This skill is only about argument resolution.
