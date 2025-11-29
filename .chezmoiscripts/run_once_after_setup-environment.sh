#!/bin/sh

# git-secrets setup (cross-platform)
git secrets --install "$HOME"/.git-templates/git-secrets
git secrets --register-aws --global

# macOS-specific settings
if [ "$CHEZMOI_OS" = "darwin" ]; then
    defaults write com.apple.dock autohide -bool true
    defaults write com.apple.dock show-recents -bool false

    defaults write com.apple.finder AppleShowAllFiles TRUE

    defaults write NSGlobalDomain NSAutomaticQuoteSubstitutionEnabled -bool false

    defaults write -g InitialKeyRepeat -int 10 # normal minimum is 15
    defaults write -g KeyRepeat -int 1 # normal minimum is 2

    killall Dock 2>/dev/null || true
fi
