# Homebrew's mise formula installs vendor_conf.d/mise-activate.fish, which runs
# `mise activate fish` before config.fish. This repo puts mise shims on PATH
# instead (ADR 0041), so stop it in two ways: this same-named file masks the
# vendor snippet, and the variable below is the snippet's own opt-out in case
# Homebrew renames the file.
set -g MISE_FISH_AUTO_ACTIVATE 0
