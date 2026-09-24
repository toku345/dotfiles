#!/bin/sh
# Explicit preparation only: never called by modify_ or an apply hook.
set -eu
fail() { echo "codex-config: $*" >&2; exit 1; }
[ "$#" -le 1 ] || fail 'usage: setup.sh [absolute Python executable]'
project_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
venv_dir="${XDG_DATA_HOME:-$HOME/.local/share}/codex-config-policy/venv"
case "$venv_dir" in
    /*) ;;
    *) echo 'codex-config: XDG_DATA_HOME must be absolute' >&2; exit 1 ;;
esac
if [ "$#" -eq 1 ]; then
    python_path=$1
else
    command -v asdf >/dev/null 2>&1 || fail 'install asdf and configure Python 3.11+; see docs/codex.md'
    python_path=$(cd -- "$HOME" && asdf which python3) ||
        fail 'configure Python 3.11+ in asdf at HOME; see docs/codex.md'
fi
case "$python_path" in
    /*) [ -x "$python_path" ] || fail 'Python executable is missing or not executable' ;;
    *) fail 'Python executable must be an absolute path' ;;
esac
# Resolve the base executable, including when a caller supplies a venv Python.
python_probe='import os, sys
if sys.version_info < (3, 11):
    raise SystemExit("Python 3.11+ is required")
print(os.path.realpath(getattr(sys, "_base_executable", sys.executable)))'
python_base=$("$python_path" -I -c "$python_probe") || fail 'cannot use the selected Python 3.11+ executable'
check_base() {
    existing_base=$("$venv_dir/bin/python" -I -c "$python_probe") ||
        fail 'venv Python cannot start; back up and recreate the venv as described in docs/codex.md'
    [ "$existing_base" = "$python_base" ] ||
        fail 'venv uses a different Python; back up and recreate the venv as described in docs/codex.md'
}
if [ -e "$venv_dir" ] || [ -L "$venv_dir" ]; then
    check_base
fi
command -v uv >/dev/null 2>&1 || {
    echo 'codex-config: install uv and Python 3.11+ before setup' >&2
    exit 1
}
# Scope the environment to this command; ignore an activated project venv.
UV_PROJECT_ENVIRONMENT="$venv_dir" uv sync --project "$project_dir" \
    --locked --no-python-downloads --python "$python_base"
check_base
"$venv_dir/bin/python" -B -c 'import sys; sys.path.insert(0, sys.argv[1]); from merge import check_environment; check_environment()' "$project_dir"
