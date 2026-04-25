#!/bin/sh

set -eu

codex_dir="$HOME/.codex"
managed="$codex_dir/config.chezmoi.toml"
live="$codex_dir/config.toml"

if [ ! -f "$managed" ]; then
    printf 'Error: managed baseline %s is missing (chezmoi source drift?)\n' "$managed" >&2
    exit 1
fi

mkdir -p "$codex_dir"

if [ ! -f "$live" ]; then
    tmp=$(mktemp "$codex_dir/config.toml.tmp.XXXXXX")
    trap 'rm -f "$tmp"' EXIT
    cp "$managed" "$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$live"
    trap - EXIT
    printf '%s\n' "Initialized ~/.codex/config.toml from ~/.codex/config.chezmoi.toml"
fi
