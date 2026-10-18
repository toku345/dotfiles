#!/bin/sh
set -eu
# Keep the existing minimum-package script byte-for-byte unchanged: run_once
# uses content hashes, so editing it would replay unrelated package installs.
# Homebrew and its PATH are prerequisites on both supported platforms.
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_UPGRADE=1
export HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1
export HOMEBREW_CASK_OPTS=--require-sha
export HOMEBREW_UPDATE_TO_TAG=1
export HOMEBREW_NO_VERIFY_ATTESTATIONS=1

case "${CHEZMOI_OS:-}" in
    darwin|linux) ;;
    *) echo "Error: unsupported CHEZMOI_OS='${CHEZMOI_OS:-unset}'" >&2; exit 1 ;;
esac

brew install bash
