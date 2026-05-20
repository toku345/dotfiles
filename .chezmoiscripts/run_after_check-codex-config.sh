#!/bin/sh

set -eu

codex_dir="$HOME/.codex"
managed="$codex_dir/config.chezmoi.toml"
live="$codex_dir/config.toml"
state="$codex_dir/.baseline-hash"

[ -f "$managed" ] || exit 0

mkdir -p "$codex_dir"

compute_sha256() {
    file=$1

    if command -v sha256sum >/dev/null 2>&1; then
        line=$(sha256sum "$file") || return 1
    elif command -v shasum >/dev/null 2>&1; then
        line=$(shasum -a 256 "$file") || return 1
    else
        printf '%s\n' "error: neither sha256sum nor shasum is available" >&2
        return 1
    fi

    hash=${line%% *}
    if [ -z "$hash" ]; then
        printf '%s\n' "error: empty sha256 for $file" >&2
        return 1
    fi
    printf '%s\n' "$hash"
}

managed_hash=$(compute_sha256 "$managed") || {
    printf '%s\n' "error: failed to compute sha256 for $managed" >&2
    exit 1
}

# Case 1: live 不在 → bootstrap
if [ ! -f "$live" ]; then
    install -m 600 "$managed" "$live"
    printf '%s\n' "$managed_hash" > "$state"
    chmod 600 "$state"
    printf '%s\n' "Initialized ~/.codex/config.toml from baseline"
    exit 0
fi

# Case 2: state 不在 → seed (safe) or block (unverified migration)
if [ ! -f "$state" ]; then
    if cmp -s "$managed" "$live"; then
        # Case 2b: live == baseline → safely seed
        printf '%s\n' "$managed_hash" > "$state"
        chmod 600 "$state"
        exit 0
    fi
    # Case 2a: live != baseline → unverified migration, require explicit ACK
    cat >&2 <<'MSG'

========================================
 Codex baseline: unverified migration (chezmoi apply blocked)
========================================

First apply with hash-based drift detection. Baseline and live differ.

This could mean:
  (a) Codex has written local-only sections
      (projects.*, mcp_servers.*, notice.*) -- expected, no merge needed
  (b) This host missed an earlier baseline update -- merge required

Review:
  diff -u ~/.codex/config.toml ~/.codex/config.chezmoi.toml

If (b), merge baseline updates into ~/.codex/config.toml first.

Then ACK the current baseline:
  hash=$(sha256sum ~/.codex/config.chezmoi.toml 2>/dev/null || shasum -a 256 ~/.codex/config.chezmoi.toml) &&
  printf '%s\n' "${hash%% *}" > ~/.codex/.baseline-hash &&
  chmod 600 ~/.codex/.baseline-hash

Re-run: chezmoi apply

========================================

MSG
    exit 1
fi

# Case 3: state == current baseline hash → no-op
if [ "$(cat "$state")" = "$managed_hash" ]; then
    exit 0
fi

# Case 4: baseline updated since last ACK → blocking
cat >&2 <<'MSG'

========================================
 Codex baseline updated (chezmoi apply blocked)
========================================

The managed baseline has changed since the last recorded merge.

Review:
  diff -u ~/.codex/config.toml ~/.codex/config.chezmoi.toml

Merge baseline updates into ~/.codex/config.toml. Keep local-only sections
documented in docs/codex.md. After merging, ACK the new baseline:
  hash=$(sha256sum ~/.codex/config.chezmoi.toml 2>/dev/null || shasum -a 256 ~/.codex/config.chezmoi.toml) &&
  printf '%s\n' "${hash%% *}" > ~/.codex/.baseline-hash &&
  chmod 600 ~/.codex/.baseline-hash

Then re-run: chezmoi apply

========================================

MSG
exit 1
