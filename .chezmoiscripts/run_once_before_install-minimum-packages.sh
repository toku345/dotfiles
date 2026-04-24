#!/bin/sh
set -eu
# Minimum package installation (OS-aware)

if [ "$CHEZMOI_OS" = "darwin" ]; then
    # ==== macOS: Homebrew ====
    brew update
    brew install coreutils git git-secrets git-delta starship fzf eza bat fd ripgrep
    brew install tmux direnv shadowenv asdf age fish nano aspell gh
    brew install coderabbitai/tap/git-gtr
    brew install --cask karabiner-elements
    brew install --cask font-fira-code-nerd-font font-fira-mono-nerd-font \
                         font-hack-nerd-font font-hackgen-nerd

elif [ "$CHEZMOI_OS" = "linux" ]; then
    # ==== Linux: apt (OS prereqs) + Linuxbrew (apps) ====
    sudo apt-get update
    sudo apt-get install -y build-essential curl file git procps

    if [ ! -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
        echo "Error: Linuxbrew not found or not executable at /home/linuxbrew/.linuxbrew. See docs/linux-setup.md" >&2
        exit 1
    fi
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"

    brew update
    brew install gh tmux starship fzf eza bat fd ripgrep \
                 git-delta direnv nano aspell git-secrets
    brew install coderabbitai/tap/git-gtr

else
    echo "Error: unsupported CHEZMOI_OS='${CHEZMOI_OS:-unset}'" >&2
    exit 1
fi
