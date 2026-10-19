#!/usr/bin/env bash
# shellcheck shell=bash
# CI checks the complete shell inventory; Stop hooks check only changed files.
set -Eeuo pipefail

inventory=$(mktemp)
trap 'rm -f "$inventory"' EXIT
# Capture discovery before looping so a missing directory or find failure cannot
# silently turn the lint job green through a process substitution.
find .chezmoiscripts dot_local/bin dot_local/lib dot_git-template/hooks \
  tests/bats .claude/hooks .codex/hooks private_dot_codex private_dot_codex-fugu \
  scripts/codex-config scripts/hooks \
  -type f \( -name '*.sh' -o -name '*.bash' -o -name '*.sh.tmpl' \
  -o -name 'executable_*' -o -path 'tests/bats/bin/*' \
  -o -name 'modify_*' \) -print0 > "$inventory"

failed=0
while IFS= read -r -d '' script; do
  case "$script" in
    *.sh.tmpl)
      echo "Checking template: $script"
      sed 's/{{[^}]*}}/PLACEHOLDER/g' "$script" | \
        shellcheck --severity=warning - || failed=1
      continue
      ;;
    tests/bats/*.bash|tests/bats/bin/*|.claude/hooks/*.sh|.codex/hooks/*.sh|scripts/hooks/*.sh|dot_local/lib/*.sh)
      # Source helpers need lint even when they intentionally lack a shebang.
      ;;
    *)
      shebang=$(head -n1 "$script")
      if ! [[ "$shebang" =~ ^#!.*[[:space:]/](bash|sh|dash|ksh|zsh)([[:space:]]|$) ]]; then
        echo "Skipping non-shell script: $script"
        continue
      fi
      ;;
  esac
  echo "Checking: $script"
  shellcheck --severity=warning "$script" || failed=1
done < "$inventory"

exit "$failed"
