#!/bin/sh
set -eu

# Chezmoi replaces a pre-existing target when changing it to a managed symlink.
# Refuse that data-loss path: preserve any real file or directory outside the
# target first, then remove it and re-run the apply.
destination="$PWD"
for target in \
    "$destination/.codex-fugu/AGENTS.md" \
    "$destination/.codex-fugu/agents" \
    "$destination/.codex-fugu/rules/managed.rules"
do
    if [ -e "$target" ] && [ ! -L "$target" ]; then
        printf '%s\n' \
            "codex-fugu: refusing to replace existing non-symlink target: $target" \
            "Back it up and remove it before applying the shared static files." >&2
        exit 1
    fi
done
