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
    exit 0
fi

if cmp -s "$managed" "$live"; then
    exit 0
fi

cat <<'MSG'

========================================
 Codex config: manual merge needed
========================================

Managed baseline:
  ~/.codex/config.chezmoi.toml

Live config used by Codex:
  ~/.codex/config.toml

Review and merge carefully:
  diff -u ~/.codex/config.toml ~/.codex/config.chezmoi.toml

Keep these local-only sections in ~/.codex/config.toml:
  - [projects."..."]
  - [mcp_servers.*]
  - [notice.*]

========================================

MSG
