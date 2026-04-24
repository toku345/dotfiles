#!/bin/sh

set -eu

codex_dir="$HOME/.codex"
managed="$codex_dir/config.chezmoi.toml"
live="$codex_dir/config.toml"

[ -f "$managed" ] || exit 0

mkdir -p "$codex_dir"

if [ ! -f "$live" ]; then
    cp "$managed" "$live"
    chmod 600 "$live" 2>/dev/null || true
    printf '%s\n' "Initialized ~/.codex/config.toml from ~/.codex/config.chezmoi.toml"
fi
