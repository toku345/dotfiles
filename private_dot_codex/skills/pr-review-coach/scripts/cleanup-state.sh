#!/usr/bin/env bash
# shellcheck shell=bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage: cleanup-state.sh [options]

Prune pr-review-coach state files from the external Codex state directory.

Options:
  --state-root DIR        State root. Default:
                          ${CODEX_PR_REVIEW_COACH_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/codex/pr-review-coach}
  --max-age-days N        Delete state files older than N days. Default: 30.
  --max-files-per-repo N  Keep the N newest state files per repo. Default: 20.
                          Files passed with --current are always preserved,
                          even when that exceeds this cap.
  --current PATH          Never delete this state file. May be repeated.
  --dry-run               Print files that would be deleted without deleting.
  -h, --help              Show this help.
USAGE
}

default_state_root() {
  local base="${CODEX_PR_REVIEW_COACH_STATE_ROOT:-}"
  if [[ -z "$base" ]]; then
    base="${XDG_STATE_HOME:-$HOME/.local/state}/codex/pr-review-coach"
  fi
  printf '%s\n' "$base"
}

is_non_negative_int() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

abs_path() {
  local path="$1"
  if [[ "$path" == /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s/%s\n' "$PWD" "$path"
  fi
}

file_mtime() {
  local file="$1"
  if stat -c '%Y' "$file" >/dev/null 2>&1; then
    stat -c '%Y' "$file"
  else
    stat -f '%m' "$file"
  fi
}

is_current_file() {
  local candidate
  candidate="$(abs_path "$1")"
  local current
  for current in "${current_files[@]}"; do
    [[ "$candidate" == "$current" ]] && return 0
  done
  return 1
}

is_current_ancestor_dir() {
  local candidate
  candidate="$(abs_path "$1")"
  local current
  for current in "${current_files[@]}"; do
    [[ "$current" == "$candidate"/* ]] && return 0
  done
  return 1
}

delete_file() {
  local file="$1"
  is_current_file "$file" && return 0
  if (( dry_run )); then
    printf 'would delete %s\n' "$file"
  else
    rm -f -- "$file"
  fi
}

cleanup_tmp_dir() {
  [[ -n "${tmp_dir:-}" ]] || return 0
  rm -rf -- "$tmp_dir"
}

enumerate_state_files() {
  local root="$1" out="$2"
  if ! find "$root" -type f -name '*.md' -print0 >"$out"; then
    printf 'failed to enumerate state files under %s\n' "$root" >&2
    exit 1
  fi
}

enumerate_repo_dirs() {
  local root="$1" out="$2"
  if ! find "$root" -mindepth 1 -maxdepth 1 -type d -print0 >"$out"; then
    printf 'failed to enumerate repo state directories under %s\n' "$root" >&2
    exit 1
  fi
}

enumerate_repo_files() {
  local repo_dir="$1" out="$2"
  if ! find "$repo_dir" -type f -name '*.md' -print0 >"$out"; then
    printf 'failed to enumerate state files under %s\n' "$repo_dir" >&2
    exit 1
  fi
}

sort_repo_files() {
  local repo_dir="$1" in_file="$2" out_file="$3"
  if ! sort -rn "$in_file" >"$out_file"; then
    printf 'failed to sort state files under %s\n' "$repo_dir" >&2
    exit 1
  fi
}

state_root="$(default_state_root)"
max_age_days="${CODEX_PR_REVIEW_COACH_MAX_AGE_DAYS:-30}"
max_files_per_repo="${CODEX_PR_REVIEW_COACH_MAX_FILES_PER_REPO:-20}"
dry_run=0
current_files=()
tmp_dir=""

while (($#)); do
  case "$1" in
    --state-root)
      [[ $# -ge 2 ]] || { printf 'missing value for --state-root\n' >&2; exit 2; }
      state_root="$2"
      shift 2
      ;;
    --max-age-days)
      [[ $# -ge 2 ]] || { printf 'missing value for --max-age-days\n' >&2; exit 2; }
      max_age_days="$2"
      shift 2
      ;;
    --max-files-per-repo)
      [[ $# -ge 2 ]] || { printf 'missing value for --max-files-per-repo\n' >&2; exit 2; }
      max_files_per_repo="$2"
      shift 2
      ;;
    --current)
      [[ $# -ge 2 ]] || { printf 'missing value for --current\n' >&2; exit 2; }
      current_files+=("$(abs_path "$2")")
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

is_non_negative_int "$max_age_days" || {
  printf '%s\n' "--max-age-days must be a non-negative integer: $max_age_days" >&2
  exit 2
}
is_non_negative_int "$max_files_per_repo" || {
  printf '%s\n' "--max-files-per-repo must be a non-negative integer: $max_files_per_repo" >&2
  exit 2
}

state_root="$(abs_path "$state_root")"
if [[ -z "$state_root" || "$state_root" == "/" ]]; then
  printf 'refusing unsafe state root: %s\n' "$state_root" >&2
  exit 2
fi

repos_dir="$state_root/repos"
[[ -d "$repos_dir" ]] || exit 0

now="$(date +%s)"
max_age_seconds=$((max_age_days * 86400))

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/pr-review-coach-cleanup.XXXXXX")" || {
  printf 'failed to create temporary directory\n' >&2
  exit 1
}
trap cleanup_tmp_dir EXIT

state_files="$tmp_dir/state-files.nul"
repo_dirs="$tmp_dir/repo-dirs.nul"
repo_files="$tmp_dir/repo-files.nul"
repo_mtimes="$tmp_dir/repo-mtimes.tsv"
repo_sorted="$tmp_dir/repo-sorted.tsv"
empty_dirs="$tmp_dir/empty-dirs.nul"

enumerate_state_files "$repos_dir" "$state_files"
while IFS= read -r -d '' file; do
  mtime="$(file_mtime "$file")"
  age=$((now - mtime))
  if (( age > max_age_seconds )); then
    delete_file "$file"
  fi
done <"$state_files"

enumerate_repo_dirs "$repos_dir" "$repo_dirs"
while IFS= read -r -d '' repo_dir; do
  count=0
  enumerate_repo_files "$repo_dir" "$repo_files"
  : >"$repo_mtimes"
  while IFS= read -r -d '' file; do
    printf '%s\t%s\n' "$(file_mtime "$file")" "$file" >>"$repo_mtimes"
  done <"$repo_files"
  sort_repo_files "$repo_dir" "$repo_mtimes" "$repo_sorted"

  while IFS=$'\t' read -r _mtime file; do
    [[ -n "${file:-}" ]] || continue
    [[ -f "$file" ]] || continue
    count=$((count + 1))
    if (( count > max_files_per_repo )); then
      delete_file "$file"
    fi
  done <"$repo_sorted"
done <"$repo_dirs"

if (( ! dry_run )); then
  if ! find "$repos_dir" -depth -type d -empty -print0 >"$empty_dirs"; then
    printf 'failed to enumerate empty state directories under %s\n' "$repos_dir" >&2
    exit 1
  fi
  while IFS= read -r -d '' dir; do
    is_current_ancestor_dir "$dir" && continue
    if ! rmdir -- "$dir"; then
      printf 'failed to remove empty state directory: %s\n' "$dir" >&2
      exit 1
    fi
  done <"$empty_dirs"
fi
