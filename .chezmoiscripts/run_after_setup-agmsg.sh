#!/bin/sh
set -eu

AGMSG_REPO="https://github.com/fujibee/agmsg.git"
AGMSG_REF="d3dec76be2bbfd0b034f200dbccb511be7008431"
AGMSG_CMD="agmsg"

agents_dir="$HOME/.agents"
skill_dir="$agents_dir/skills/$AGMSG_CMD"
state_file="$skill_dir/.dotfiles-agmsg-ref"
codex_config="$HOME/.codex/config.toml"

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        printf '%s\n' "error: $1 is required to install agmsg" >&2
        return 1
    fi
}

current_ref=""
if [ -f "$state_file" ]; then
    current_ref=$(cat "$state_file")
fi

if [ -f "$skill_dir/.agmsg" ] && [ "$current_ref" = "$AGMSG_REF" ]; then
    exit 0
fi

require_command bash
require_command git
require_command sqlite3

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/agmsg-setup.XXXXXX") || {
    printf '%s\n' "error: cannot create temporary directory for agmsg setup" >&2
    exit 1
}
trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM

before_config="$tmpdir/codex-config.before"
after_config="$tmpdir/codex-config.after"
diff_file="$tmpdir/codex-config.diff"

if [ -f "$codex_config" ]; then
    cp "$codex_config" "$before_config"
else
    : > "$before_config"
fi

clone_dir="$tmpdir/agmsg"
git clone --quiet "$AGMSG_REPO" "$clone_dir"
git -C "$clone_dir" checkout --quiet --detach "$AGMSG_REF"

actual_ref=$(git -C "$clone_dir" rev-parse HEAD)
if [ "$actual_ref" != "$AGMSG_REF" ]; then
    printf '%s\n' "error: agmsg checkout mismatch: expected $AGMSG_REF, got $actual_ref" >&2
    exit 1
fi

if [ -f "$skill_dir/.agmsg" ]; then
    bash "$clone_dir/install.sh" --update --cmd "$AGMSG_CMD"
else
    bash "$clone_dir/install.sh" --cmd "$AGMSG_CMD"
fi

if [ -f "$codex_config" ]; then
    cp "$codex_config" "$after_config"
else
    : > "$after_config"
fi

if ! diff -u "$before_config" "$after_config" > "$diff_file"; then
    bad_lines="$tmpdir/codex-config.bad"
    : > "$bad_lines"
    while IFS= read -r line; do
        case "$line" in
            ---*|+++*|@@*)
                continue
                ;;
            [-+]*)
                content=${line#?}
                case "$content" in
                    ""|"[sandbox_workspace_write]"|writable_roots*|*"$skill_dir/db"*|*"$skill_dir/teams"*|*"$skill_dir/run"*)
                        ;;
                    *)
                        printf '%s\n' "$line" >> "$bad_lines"
                        ;;
                esac
                ;;
        esac
    done < "$diff_file"

    if [ -s "$bad_lines" ]; then
        cat >&2 <<'MSG'

========================================
 agmsg setup changed ~/.codex/config.toml unexpectedly
========================================

The agmsg installer is allowed to add Codex writable_roots for:
  ~/.agents/skills/agmsg/db
  ~/.agents/skills/agmsg/teams
  ~/.agents/skills/agmsg/run

It made additional changes. Review ~/.codex/config.toml and restore or accept
them manually before re-running chezmoi apply.

Unexpected diff lines:
MSG
        cat "$bad_lines" >&2
        printf '%s\n' "========================================" >&2
        exit 1
    fi
fi

mkdir -p "$skill_dir"
printf '%s\n' "$AGMSG_REF" > "$state_file"
chmod 600 "$state_file"

printf '%s\n' "agmsg installed at $skill_dir ($AGMSG_REF)"
