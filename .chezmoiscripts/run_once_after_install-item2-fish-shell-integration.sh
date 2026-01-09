#!/usr/bin/env sh

# iTerm2 is macOS-only
if [ "$CHEZMOI_OS" != "darwin" ]; then
    echo "Skipping iTerm2 shell integration (not macOS)"
    exit 0
fi

mkdir -p "$HOME/.config/iterm2"
curl -L https://iterm2.com/shell_integration/fish -o "$HOME/.config/iterm2/shell_integration.fish"
