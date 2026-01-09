#!/bin/bash

input=$(cat)

# Extract data from JSON input
model=$(echo "$input" | jq -r '.model.display_name')
dir=$(basename "$(echo "$input" | jq -r '.workspace.current_dir')")
usage=$(echo "$input" | jq '.context_window.current_usage')

# Calculate context window percentage
if [ "$usage" != "null" ]; then
  current=$(echo "$usage" | jq '.input_tokens + .cache_creation_input_tokens + .cache_read_input_tokens')
  size=$(echo "$input" | jq '.context_window.context_window_size')
  remaining=$((size - current))
  pct=$((current * 100 / size))

  # Format with K suffix for readability
  remaining_k=$((remaining / 1000))

  token_info=$(printf "\033[35m%d%% ctx\033[0m (\033[33m%dK remain\033[0m)" "$pct" "$remaining_k")
else
  token_info="\033[35m0% ctx\033[0m"
fi

# Get git branch
cd "$(echo "$input" | jq -r '.workspace.current_dir')" 2>/dev/null
branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)

# Build output
if [ -n "$branch" ]; then
  printf "\033[36m%s\033[0m in \033[32m%s\033[0m on \033[33m%s\033[0m | %s\n" "$model" "$dir" "$branch" "$token_info"
else
  printf "\033[36m%s\033[0m in \033[32m%s\033[0m | %s\n" "$model" "$dir" "$token_info"
fi
