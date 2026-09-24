#!/bin/sh
# Explicit preparation only: never called by modify_ or an apply hook.
set -eu
project_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
venv_dir="${XDG_DATA_HOME:-$HOME/.local/share}/codex-config-policy/venv"
case "$venv_dir" in
    /*) ;;
    *) echo 'codex-config: XDG_DATA_HOME must be absolute' >&2; exit 1 ;;
esac
command -v uv >/dev/null 2>&1 || {
    echo 'codex-config: install uv and Python 3.11+ before setup' >&2
    exit 1
}
# Scope the environment to this command; ignore an activated project venv.
UV_PROJECT_ENVIRONMENT="$venv_dir" uv sync --project "$project_dir" \
    --locked --no-python-downloads --python python3
"$venv_dir/bin/python" -B -c 'import sys; sys.path.insert(0, sys.argv[1]); from merge import check_environment; check_environment()' "$project_dir"
