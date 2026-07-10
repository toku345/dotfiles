#!/bin/sh
set -eu

CC_SESSION_FINDER_REPO="https://github.com/jugyo/cc-session-finder.git"
CC_SESSION_FINDER_REF="68fcd96659af648dbf4204791b9bffddca249e72"
CC_SESSION_FINDER_MCP_NAME="cc-session-finder"

cargo_home=${CARGO_HOME:-"$HOME/.cargo"}
install_root=${CARGO_INSTALL_ROOT:-"$cargo_home"}
managed_binary="$install_root/bin/cc-session-finder"

info() {
    printf '%s\n' "$*" >&2
}

show_prereq_message() {
    cat >&2 <<MSG

========================================
 cc-session-finder MCP setup skipped
========================================

cc-session-finder is not installed and cargo is not available.

Install Rust with rustup, then re-run:
  chezmoi apply

This setup will install cc-session-finder from:
  $CC_SESSION_FINDER_REPO
  rev $CC_SESSION_FINDER_REF

========================================

MSG
}

find_cc_session_finder() {
    if [ -x "$managed_binary" ]; then
        printf '%s\n' "$managed_binary"
        return 0
    fi

    if command -v cc-session-finder >/dev/null 2>&1; then
        command -v cc-session-finder
        return 0
    fi

    return 1
}

find_cargo() {
    if command -v cargo >/dev/null 2>&1; then
        command -v cargo
        return 0
    fi

    if [ -x "$cargo_home/bin/cargo" ]; then
        printf '%s\n' "$cargo_home/bin/cargo"
        return 0
    fi

    return 1
}

install_cc_session_finder() {
    cargo_bin=$1
    force_install=$2

    set -- install \
        --git "$CC_SESSION_FINDER_REPO" \
        --rev "$CC_SESSION_FINDER_REF" \
        --locked \
        --root "$install_root" \
        --bin cc-session-finder
    if [ "$force_install" = "1" ]; then
        set -- "$@" --force
    fi

    info "Installing cc-session-finder at pinned rev $CC_SESSION_FINDER_REF"
    if ! "$cargo_bin" "$@"; then
        printf '%s\n' "error: cargo install failed for rev $CC_SESSION_FINDER_REF" >&2
        return 1
    fi

    if [ ! -x "$managed_binary" ]; then
        printf '%s\n' "error: cargo install succeeded but $managed_binary is not executable; expected cargo --root $install_root to create it" >&2
        return 1
    fi
}

ensure_cc_session_finder() {
    reinstall=${CC_SESSION_FINDER_REINSTALL:-0}
    case "$reinstall" in
        0|1) ;;
        *)
            printf '%s\n' "error: CC_SESSION_FINDER_REINSTALL must be 0 or 1 (got: $reinstall)" >&2
            return 1
            ;;
    esac

    case "$install_root" in
        /*) ;;
        *)
            printf '%s\n' "error: CARGO_INSTALL_ROOT/CARGO_HOME must resolve to an absolute path (got: $install_root)" >&2
            return 1
            ;;
    esac

    if [ "$reinstall" = "0" ]; then
        if binary=$(find_cc_session_finder); then
            printf '%s\n' "$binary"
            return 0
        fi
    fi

    if cargo_path=$(find_cargo); then
        install_cc_session_finder "$cargo_path" "$reinstall" || return $?
        printf '%s\n' "$managed_binary"
        return 0
    fi

    if [ "$reinstall" = "1" ]; then
        printf '%s\n' "error: CC_SESSION_FINDER_REINSTALL=1 requested, but cargo is unavailable. Install Rust with rustup, then re-run: CC_SESSION_FINDER_REINSTALL=1 chezmoi apply -v" >&2
        return 1
    fi

    show_prereq_message
    return 2
}

mcp_entry_matches() {
    binary=$1
    entry=$2

    # Claude Code does not expose JSON for `mcp get`; keep this parser narrow.
    printf '%s\n' "$entry" | grep -F "Scope: User config" >/dev/null 2>&1 || return 1
    printf '%s\n' "$entry" | grep -F "Command: $binary" >/dev/null 2>&1 || return 1
    printf '%s\n' "$entry" | grep -F "Args: mcp" >/dev/null 2>&1 || return 1
}

ensure_claude_mcp() {
    binary=$1

    if ! command -v claude >/dev/null 2>&1; then
        info "cc-session-finder installed at $binary, but claude is not available; skipping MCP registration"
        return 0
    fi

    entry=""
    if entry=$(claude mcp get "$CC_SESSION_FINDER_MCP_NAME" 2>/dev/null); then
        if mcp_entry_matches "$binary" "$entry"; then
            return 0
        fi

        if printf '%s\n' "$entry" | grep -F "Scope: User config" >/dev/null 2>&1; then
            claude mcp remove "$CC_SESSION_FINDER_MCP_NAME" -s user >/dev/null
        else
            cat >&2 <<MSG
error: MCP server "$CC_SESSION_FINDER_MCP_NAME" already exists outside user config.
Remove or rename that server, then re-run:
  chezmoi apply
MSG
            return 1
        fi
    fi

    claude mcp add --scope user "$CC_SESSION_FINDER_MCP_NAME" -- "$binary" mcp >/dev/null
}

codex_mcp_entry_matches() {
    binary=$1
    entry=$2

    # Keep text matching exact so prefix-shaped stale entries are replaced.
    printf '%s\n' "$entry" | grep -Fx "  transport: stdio" >/dev/null 2>&1 || return 1
    printf '%s\n' "$entry" | grep -Fx "  command: $binary" >/dev/null 2>&1 || return 1
    printf '%s\n' "$entry" | grep -Fx "  args: mcp" >/dev/null 2>&1 || return 1
}

codex_mcp_get_missing_error() {
    err_file=$1

    grep -F "No MCP server named '$CC_SESSION_FINDER_MCP_NAME' found." "$err_file" >/dev/null 2>&1
}

ensure_codex_mcp() {
    binary=$1

    if ! command -v codex >/dev/null 2>&1; then
        info "cc-session-finder installed at $binary, but codex is not available; skipping MCP registration"
        return 0
    fi

    entry=""
    get_err=$(mktemp "${TMPDIR:-/tmp}/cc-session-finder-codex-mcp.XXXXXX") || return 1
    if entry=$(codex mcp get "$CC_SESSION_FINDER_MCP_NAME" 2>"$get_err"); then
        if codex_mcp_entry_matches "$binary" "$entry"; then
            rm -f "$get_err"
            return 0
        fi

        rm -f "$get_err"
        codex mcp remove "$CC_SESSION_FINDER_MCP_NAME" >/dev/null
    else
        rc=$?
        if ! codex_mcp_get_missing_error "$get_err"; then
            printf 'error: failed to inspect Codex MCP server "%s":\n' "$CC_SESSION_FINDER_MCP_NAME" >&2
            cat "$get_err" >&2
            rm -f "$get_err"
            return "$rc"
        fi
        rm -f "$get_err"
    fi

    codex mcp add "$CC_SESSION_FINDER_MCP_NAME" -- "$binary" mcp >/dev/null
}

main() {
    if binary=$(ensure_cc_session_finder); then
        :
    else
        rc=$?
        if [ "$rc" -eq 2 ]; then
            return 0
        fi
        return "$rc"
    fi

    if [ -z "$binary" ]; then
        return 0
    fi

    ensure_claude_mcp "$binary"
    ensure_codex_mcp "$binary"
}

if [ "${CC_SESSION_FINDER_SETUP_SOURCE_ONLY:-0}" != "1" ]; then
    main "$@"
fi
