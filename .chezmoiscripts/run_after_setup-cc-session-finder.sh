#!/bin/sh
set -eu

CC_SESSION_FINDER_REPO="https://github.com/jugyo/cc-session-finder.git"
CC_SESSION_FINDER_REF="68fcd96659af648dbf4204791b9bffddca249e72"

cargo_home=${CARGO_HOME:-"$HOME/.cargo"}
install_root=${CARGO_INSTALL_ROOT:-"$cargo_home"}
managed_binary="$install_root/bin/cc-session-finder"

info() {
    printf '%s\n' "$*" >&2
}

show_prereq_message() {
    cat >&2 <<MSG

========================================
 cc-session-finder CLI setup skipped
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
}

if [ "${CC_SESSION_FINDER_SETUP_SOURCE_ONLY:-0}" != "1" ]; then
    main "$@"
fi
