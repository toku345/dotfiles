#!/bin/bash

# jq is required for JSON parsing
if ! command -v jq &>/dev/null; then
  printf "\033[31mjq required\033[0m\n"
  exit 1
fi

input=$(cat)

# Validate input
if [ -z "$input" ]; then
  printf "\033[31mNo input\033[0m\n"
  exit 1
fi

if ! echo "$input" | jq -e . >/dev/null 2>&1; then
  printf "\033[31mInvalid JSON\033[0m\n"
  exit 1
fi

# Extract all data in single jq call
IFS=$'\t' read -r model dir current size target_dir < <(echo "$input" | jq -r '[
  .model.display_name // "unknown",
  (.workspace.current_dir // "" | split("/") | .[-1] // ""),
  ((.context_window.current_usage.input_tokens // 0) + (.context_window.current_usage.cache_creation_input_tokens // 0) + (.context_window.current_usage.cache_read_input_tokens // 0)),
  (.context_window.context_window_size // 0),
  .workspace.current_dir // ""
] | @tsv')

# Calculate context window percentage with zero-division guard
if [ "$size" -gt 0 ] 2>/dev/null; then
  remaining=$((size - current))
  pct=$((current * 100 / size))
  remaining_k=$((remaining / 1000))
  token_info=$(printf "\033[35m%d%% ctx\033[0m (\033[33m%dK remain\033[0m)" "$pct" "$remaining_k")
else
  token_info="\033[35m0% ctx\033[0m"
fi

# Get git branch
branch=""
if [ -n "$target_dir" ]; then
  branch=$(git -C "$target_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)
fi

# Build output
if [ -n "$branch" ]; then
  printf "\033[36m%s\033[0m in \033[32m%s\033[0m on \033[33m%s\033[0m | %b\n" "$model" "$dir" "$branch" "$token_info"
else
  printf "\033[36m%s\033[0m in \033[32m%s\033[0m | %b\n" "$model" "$dir" "$token_info"
fi
