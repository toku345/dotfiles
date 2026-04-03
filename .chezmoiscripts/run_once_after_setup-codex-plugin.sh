#!/bin/sh

# Check if codex-plugin-cc is installed in Claude Code
if ! grep -q '"codex@openai-codex"' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null; then
    echo ""
    echo "========================================"
    echo " codex-plugin-cc (Claude Code plugin)"
    echo "========================================"
    echo ""
    echo "Codex plugin for Claude Code is not installed."
    echo "To install, run the following commands in Claude Code:"
    echo ""
    echo "  /plugin marketplace add openai/codex-plugin-cc"
    echo "  /plugin install codex@openai-codex"
    echo "  /reload-plugins"
    echo "  /codex:setup"
    echo ""
    echo "Prerequisites:"
    echo "  - Node.js >= 18.18"
    echo "  - Codex CLI (npm install -g @openai/codex)"
    echo "  - ChatGPT subscription or OpenAI API key"
    echo ""
    echo "See: https://github.com/toku345/dotfiles/blob/main/docs/claude-code-plugins.md"
    echo "========================================"
    echo ""
fi
