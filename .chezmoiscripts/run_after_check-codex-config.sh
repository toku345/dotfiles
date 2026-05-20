#!/bin/sh

set -eu

codex_dir="$HOME/.codex"
managed="$codex_dir/config.chezmoi.toml"
live="$codex_dir/config.toml"

[ -f "$managed" ] || exit 0

mkdir -p "$codex_dir"

if [ ! -f "$live" ]; then
    install -m 600 "$managed" "$live"
    printf '%s\n' "Initialized ~/.codex/config.toml from baseline"
    exit 0
fi

if cmp -s "$managed" "$live"; then
    exit 0
fi

cat <<'MSG' >&2

========================================
 Codex config: drift detected (chezmoi apply blocked)
========================================

Run:
  diff -u ~/.codex/config.toml ~/.codex/config.chezmoi.toml

Merge baseline updates into ~/.codex/config.toml while keeping the
local-only sections documented in docs/codex.md.

After merge, re-run: chezmoi apply

========================================

MSG
exit 1
