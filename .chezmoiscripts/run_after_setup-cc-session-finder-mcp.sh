#!/bin/sh
set -eu

CC_SESSION_FINDER_REPO="https://github.com/jugyo/cc-session-finder.git"
CC_SESSION_FINDER_REF="68fcd96659af648dbf4204791b9bffddca249e72"
CC_SESSION_FINDER_MCP_NAME="cc-session-finder"

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
    if command -v cc-session-finder >/dev/null 2>&1; then
        command -v cc-session-finder
        return 0
    fi

    cargo_home=${CARGO_HOME:-"$HOME/.cargo"}
    binary="$cargo_home/bin/cc-session-finder"
    if [ -x "$binary" ]; then
        printf '%s\n' "$binary"
        return 0
    fi

    return 1
}

install_cc_session_finder() {
    if ! command -v cargo >/dev/null 2>&1; then
        show_prereq_message
        return 2
    fi

    info "Installing cc-session-finder at pinned rev $CC_SESSION_FINDER_REF"
    cargo install \
        --git "$CC_SESSION_FINDER_REPO" \
        --rev "$CC_SESSION_FINDER_REF" \
        --locked \
        --bin cc-session-finder
}

ensure_cc_session_finder() {
    if binary=$(find_cc_session_finder); then
        printf '%s\n' "$binary"
        return 0
    fi

    install_cc_session_finder || return $?

    if binary=$(find_cc_session_finder); then
        printf '%s\n' "$binary"
        return 0
    fi

    return 1
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
}

if [ "${CC_SESSION_FINDER_SETUP_SOURCE_ONLY:-0}" != "1" ]; then
    main "$@"
fi
