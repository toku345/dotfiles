#!/bin/sh

set -eu

codex_dir="$HOME/.codex"
managed="$codex_dir/config.chezmoi.toml"
live="$codex_dir/config.toml"
state="$codex_dir/.baseline-hash"

[ -f "$managed" ] || exit 0

mkdir -p "$codex_dir"

managed_hash=$(shasum -a 256 "$managed" | awk '{print $1}')

# Case 1: live 不在 → bootstrap
if [ ! -f "$live" ]; then
    install -m 600 "$managed" "$live"
    printf '%s\n' "$managed_hash" > "$state"
    chmod 600 "$state"
    printf '%s\n' "Initialized ~/.codex/config.toml from baseline"
    exit 0
fi

# Case 2: state 不在 → seed (migration)
if [ ! -f "$state" ]; then
    if ! cmp -s "$managed" "$live"; then
        cat >&2 <<'MSG'

========================================
 Codex baseline: hash state seeded (drift unverified)
========================================

First apply with hash-based drift detection.
Baseline and live differ; expected if Codex has already written
local-only sections (projects.*, mcp_servers.*, notice.*).

If this host may have missed a baseline update, review:
  diff -u ~/.codex/config.toml ~/.codex/config.chezmoi.toml

Future baseline updates will block `chezmoi apply` until ACKed.

========================================

MSG
    fi
    printf '%s\n' "$managed_hash" > "$state"
    chmod 600 "$state"
    exit 0
fi

# Case 3: state == current baseline hash → no-op
if [ "$(cat "$state")" = "$managed_hash" ]; then
    exit 0
fi

# Case 4: baseline updated since last ACK → blocking
cat >&2 <<MSG

========================================
 Codex baseline updated (chezmoi apply blocked)
========================================

The managed baseline has changed since the last recorded merge.

Review:
  diff -u ~/.codex/config.toml ~/.codex/config.chezmoi.toml

Merge baseline updates into ~/.codex/config.toml. Keep local-only sections
documented in docs/codex.md. After merging, ACK the new baseline:
  shasum -a 256 ~/.codex/config.chezmoi.toml | awk '{print \$1}' > ~/.codex/.baseline-hash

Then re-run: chezmoi apply

========================================

MSG
exit 1
