#!/bin/sh

# Local secret-scan gate: a gitleaks pre-commit hook is deployed to
# ~/.git-template/hooks/pre-commit and wired via init.templateDir in
# ~/.config/git/config, so new clones/inits inherit it automatically when no
# pre-commit hook already exists. Existing repos with old git-secrets/custom
# hooks need manual inspect/replace/chain migration because git templates never
# overwrite hooks.
# See docs/adr/0028-gitleaks-secret-scanning-baseline.md.

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
