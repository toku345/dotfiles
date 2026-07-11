#!/bin/sh
set -eu

AGMSG_REPO="https://github.com/fujibee/agmsg.git"
AGMSG_REF="ea3e10f0d708a47c792682c4940b8b0736b528f9"
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

codex_config_writable_roots_delta_allowed() {
    _before=$1
    _after=$2
    _sdir=$3

    awk -v _sdir="$_sdir" '
        function collect(file, label, line, root) {
            in_section = 0
            while ((getline line < file) > 0) {
                if (line ~ /^[[:space:]]*#/ || line ~ /^[[:space:]]*$/) {
                    continue
                }
                if (line ~ /^[[:space:]]*\[sandbox_workspace_write\][[:space:]]*$/) {
                    in_section = 1
                    continue
                }
                if (line ~ /^[[:space:]]*\[/) {
                    in_section = 0
                    continue
                }
                if (in_section && line ~ /^[[:space:]]*writable_roots[[:space:]]*=/) {
                    sub(/[[:space:]]+#.*/, "", line)
                    while (match(line, /"[^"]*"/)) {
                        root = substr(line, RSTART + 1, RLENGTH - 2)
                        if (label == "before") {
                            before_roots[root] = 1
                        } else {
                            after_roots[root] = 1
                        }
                        line = substr(line, RSTART + RLENGTH)
                    }
                }
            }
            close(file)
        }
        BEGIN {
            expected[_sdir "/db"] = 1
            expected[_sdir "/teams"] = 1
            expected[_sdir "/run"] = 1
            collect(ARGV[1], "before")
            collect(ARGV[2], "after")
            ARGV[1] = ""
            ARGV[2] = ""

            for (root in before_roots) {
                if (!(root in after_roots)) {
                    exit 1
                }
            }
            for (root in after_roots) {
                if (!(root in before_roots) && !(root in expected)) {
                    exit 1
                }
            }
            for (root in expected) {
                if (!(root in after_roots)) {
                    exit 1
                }
            }
        }
    ' "$_before" "$_after"
}

# classify_codex_config_drift <before> <after> <skill_dir>
# Compare two ~/.codex/config.toml snapshots and print every diff line that is
# NOT an allowed agmsg writable_roots addition. The installer may only add the
# [sandbox_workspace_write] header and writable_roots entries for
# <skill_dir>/{db,teams,run}; anything else is unexpected and is echoed so the
# caller can report it.
# Return codes:
#   0 - comparison ran; caller inspects stdout (empty = no drift to report,
#       non-empty = the unexpected lines)
#   2 - the comparison itself failed (diff trouble: unreadable input, I/O
#       error). The caller MUST fail loud rather than treat a broken comparison
#       as "no drift".
classify_codex_config_drift() {
    _before=$1
    _after=$2
    _sdir=$3

    if _diff_out=$(diff -u "$_before" "$_after"); then
        return 0
    else
        _rc=$?
    fi
    if [ "$_rc" -ge 2 ]; then
        return 2
    fi

    printf '%s\n' "$_diff_out" | while IFS= read -r _line; do
        case "$_line" in
            ---*|+++*|@@*)
                continue
                ;;
            +*)
                _content=${_line#+}
                if [ "$_content" = "[sandbox_workspace_write]" ]; then
                    continue
                fi
                case "$_content" in
                    writable_roots*|[[:space:]]writable_roots*)
                    continue
                    ;;
                esac
                printf '%s\n' "$_line"
                ;;
            -*)
                _content=${_line#-}
                case "$_content" in
                    writable_roots*|[[:space:]]writable_roots*)
                        continue
                        ;;
                esac
                printf '%s\n' "$_line"
                ;;
        esac
    done
    if printf '%s\n' "$_diff_out" | grep -E '^[+-][[:space:]]*writable_roots[[:space:]]*=' >/dev/null 2>&1 &&
        ! codex_config_writable_roots_delta_allowed "$_before" "$_after" "$_sdir"; then
        printf '%s\n' "$_diff_out" | while IFS= read -r _line; do
            case "$_line" in
                [-+]*)
                    _content=${_line#?}
                    case "$_content" in
                        writable_roots*|[[:space:]]writable_roots*)
                            printf '%s\n' "$_line"
                            ;;
                    esac
                    ;;
            esac
        done
    fi
}

# codex_config_has_agmsg_roots <config> <skill_dir>
# Return 0 only when the live Codex config still contains all three agmsg
# runtime writable roots in the effective [sandbox_workspace_write] section.
# The idempotent fast path uses this to avoid reporting success after a manual
# or tool-driven config cleanup removed the access needed by agmsg runtime state.
codex_config_has_agmsg_roots() {
    _config=$1
    _sdir=$2

    [ -f "$_config" ] || return 1
    awk \
        -v _db="\"$_sdir/db\"" \
        -v _teams="\"$_sdir/teams\"" \
        -v _run="\"$_sdir/run\"" '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        /^[[:space:]]*\[sandbox_workspace_write\][[:space:]]*$/ {
            in_section = 1
            next
        }
        /^[[:space:]]*\[/ {
            in_section = 0
            next
        }
        in_section && /^[[:space:]]*writable_roots[[:space:]]*=/ {
            line = $0
            sub(/[[:space:]]+#.*/, "", line)
            if (index(line, _db) && index(line, _teams) && index(line, _run)) {
                found = 1
            }
        }
        END { exit found ? 0 : 1 }
    ' "$_config"
}

# assert_no_codex_config_drift <before> <after> <skill_dir>
# Fail loud (exit 1) if the agmsg installer changed ~/.codex/config.toml beyond
# the allowed writable_roots additions, or if the before/after comparison could
# not be performed at all. Returns 0 only when the delta is exactly the expected
# agmsg additions (or empty).
assert_no_codex_config_drift() {
    _before=$1
    _after=$2
    _sdir=$3

    _unexpected=""
    if _unexpected=$(classify_codex_config_drift "$_before" "$_after" "$_sdir"); then
        :
    else
        _status=$?
        if [ "$_status" -ge 2 ]; then
            printf '%s\n' "error: failed to compare ~/.codex/config.toml before and after agmsg setup; aborting" >&2
            exit 1
        fi
    fi

    if [ -n "$_unexpected" ]; then
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
        printf '%s\n' "$_unexpected" >&2
        printf '%s\n' "========================================" >&2
        exit 1
    fi
}

# Allow tests to source this script (AGMSG_SETUP_SOURCE_ONLY=1) and unit-test the
# functions above without running the network install flow.
if [ "${AGMSG_SETUP_SOURCE_ONLY:-0}" = "1" ]; then
    # `return` succeeds when sourced (tests); when run directly it fails and the
    # `exit 0` fallback runs — reachable, but static analysis cannot see it.
    # shellcheck disable=SC2317
    return 0 2>/dev/null || exit 0
fi

current_ref=""
if [ -f "$state_file" ]; then
    current_ref=$(cat "$state_file")
fi

if [ -f "$skill_dir/.agmsg" ] && [ "$current_ref" = "$AGMSG_REF" ]; then
    if ! codex_config_has_agmsg_roots "$codex_config" "$skill_dir"; then
        cat >&2 <<'MSG'
error: agmsg is installed at the pinned ref, but ~/.codex/config.toml is
missing one or more required agmsg writable_roots:
  ~/.agents/skills/agmsg/db
  ~/.agents/skills/agmsg/teams
  ~/.agents/skills/agmsg/run

Repair ~/.codex/config.toml or remove the agmsg ref marker so setup can
reinstall/update agmsg.
MSG
        exit 1
    fi
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

install_status=0
if [ -f "$skill_dir/.agmsg" ]; then
    if bash "$clone_dir/install.sh" --update --cmd "$AGMSG_CMD"; then
        :
    else
        install_status=$?
    fi
else
    if bash "$clone_dir/install.sh" --cmd "$AGMSG_CMD"; then
        :
    else
        install_status=$?
    fi
fi

if [ -f "$codex_config" ]; then
    cp "$codex_config" "$after_config"
else
    : > "$after_config"
fi

assert_no_codex_config_drift "$before_config" "$after_config" "$skill_dir"

if [ "$install_status" -ne 0 ]; then
    printf '%s\n' "error: agmsg installer failed; aborting" >&2
    exit "$install_status"
fi

if ! codex_config_has_agmsg_roots "$codex_config" "$skill_dir"; then
    cat >&2 <<'MSG'
error: agmsg installer completed, but ~/.codex/config.toml is missing one or
more required agmsg writable_roots:
  ~/.agents/skills/agmsg/db
  ~/.agents/skills/agmsg/teams
  ~/.agents/skills/agmsg/run

Review the agmsg installer output and ~/.codex/config.toml before re-running
chezmoi apply.
MSG
    exit 1
fi

mkdir -p "$skill_dir"
printf '%s\n' "$AGMSG_REF" > "$state_file"
chmod 600 "$state_file"

printf '%s\n' "agmsg installed at $skill_dir ($AGMSG_REF)"
