#!/bin/sh

# chezmoi cannot manage Claude Code plugins; display manual setup instructions when missing
plugin_file="$HOME/.claude/plugins/installed_plugins.json"
show_install_message() {
    cat <<'MSG'

========================================
 codex-plugin-cc (Claude Code plugin)
========================================

Codex plugin for Claude Code is not installed.
To install, run the following commands in Claude Code:

  /plugin marketplace add openai/codex-plugin-cc
  /plugin install codex@openai-codex
  /reload-plugins
  /codex:setup

Prerequisites:
  - Node.js >= 18.18
  - Codex CLI (npm install -g @openai/codex)
  - ChatGPT subscription or OpenAI API key

See: https://github.com/toku345/dotfiles/blob/main/docs/claude-code-plugins.md
========================================

MSG
}

if [ -f "$plugin_file" ]; then
    if ! grep -q '"codex@openai-codex"' "$plugin_file"; then
        show_install_message
    fi
else
    show_install_message
fi
