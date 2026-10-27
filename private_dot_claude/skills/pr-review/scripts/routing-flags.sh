#!/bin/sh
# Deterministic routing-flag floor for the pr-review skill's Collect step.
# The workflow OR-composes these flags with the categorizer agent's semantic
# judgment, so an agent false negative can never narrow the specialist fan-out;
# grep false positives only widen it, which is the safe direction.
#
# Usage: routing-flags.sh <base-commit> <head-ref>
# Run from inside the repository under review. Prints exactly one line,
# `commentChanges=<true|false> typeChanges=<true|false>`, and exits 0; any
# other outcome means the flags are unknown and the caller must abort.

if [ "$#" -ne 2 ]; then
  echo "usage: routing-flags.sh <base-commit> <head-ref>" >&2
  exit 2
fi
base_commit=$1
head_ref=$2

# The diff runs on its own and fails loud: a combined pipeline would let a git
# failure (bad ref, transient FS error) silently yield an empty flags_src —
# false/false flags identical to a genuine no-match, eroding the deterministic
# floor exactly when the environment misbehaves.
# .md/.mdx excluded: prose uses 'type'/'class'/'schema' constantly and would
# over-trigger the keyword patterns below. The strict 'a/', 'b/', '/dev/null'
# header forms keep removed SQL/Lua comment lines ('-- x' rendered as '--- x')
# from being eaten by a bare ^--- exclusion.
if ! flags_raw=$(git diff "$base_commit...$head_ref" -- ':(exclude)*.md' ':(exclude)*.mdx'); then
  echo "ABORT: git diff for routing flags failed" >&2
  exit 1
fi
# The two filter stages are captured separately rather than piped: sh has no
# pipefail, so a first-stage grep error would otherwise go unseen. Exit 1
# means "no lines" and is fine; exit 2+ aborts.
check_filter() {
  if [ "$1" -gt 1 ]; then
    echo "ABORT: grep filter for routing flags failed (exit $1)" >&2
    exit 1
  fi
}
changed=$(printf '%s\n' "$flags_raw" | LC_ALL=C grep -E '^[+-]')
check_filter $?
flags_src=$(printf '%s\n' "$changed" | LC_ALL=C grep -vE '^(\+\+\+|---) (a/|b/|/dev/null)')
check_filter $?

# has <grep args>: succeed when a changed line matches. A grep error (exit 2+:
# bad pattern, locale or I/O failure) aborts instead of reading as "no match",
# which would print well-formed false flags that pass the caller's check.
# The grep reads its whole input (`>/dev/null`, not `-q`), so a match never
# depends on printf surviving an early grep exit.
has() {
  printf '%s\n' "$flags_src" | LC_ALL=C grep "$@" >/dev/null
  rc=$?
  if [ "$rc" -gt 1 ]; then
    echo "ABORT: grep for routing flags failed (exit $rc)" >&2
    exit 1
  fi
  return "$rc"
}

# LC_ALL=C and POSIX classes keep BSD/GNU grep deterministic.
# Bare `type`/`schema` keywords are deliberately NOT matched — JS/JSON diffs
# contain `type: 'string'` everywhere and the flag would be always-true;
# definition-anchored false negatives are rescued by the categorizer's OR.
commentChanges=false
has -E "^[+-][[:space:]]*(#|//|/\*|\*|<!--|;|--|\"\"\"|''')" && commentChanges=true

typeChanges=false
has -E '^[+-][[:space:]]*(export[[:space:]]+)?(pub(\([^)]*\))?[[:space:]]+)?((abstract|final|data|sealed)[[:space:]]+)?(class|interface|struct|enum|trait)[[:space:]]+[A-Za-z_]' && typeChanges=true
has -E '(^|[^[:alnum:]_])type[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*(=|struct([^[:alnum:]_]|$)|interface([^[:alnum:]_]|$))' && typeChanges=true
has '@dataclass' && typeChanges=true
has -iE '(^|[^[:alnum:]_])(create|alter)[[:space:]]+(table|schema)([^[:alnum:]_]|$)' && typeChanges=true

# The readout doubles as the exit status: without it, a benign no-match on the
# trailing `has ... && ...` chain would make the script exit 1.
echo "commentChanges=$commentChanges typeChanges=$typeChanges"
