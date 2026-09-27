#!/bin/sh
# Explicit preparation only: never called by modify_ or an apply hook.
set -eu
fail() { echo "codex-config: $*" >&2; exit 1; }
[ "$#" -le 1 ] || fail 'usage: setup.sh [--upgrade-python | absolute Python executable]'
upgrade=false
explicit_python=''
case "${1-}" in
    --upgrade-python) upgrade=true ;;
    /*) explicit_python=$1 ;;
    '') [ "$#" -eq 0 ] || fail 'Python executable must be an absolute path' ;;
    *) fail 'usage: setup.sh [--upgrade-python | absolute Python executable]' ;;
esac
command -v uv >/dev/null 2>&1 || fail 'install uv with Homebrew before setup'
project_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
series=$(cat "$project_dir/.python-version")
printf '%s\n' "$series" | grep -Eq '^[0-9]+\.[0-9]+$' || fail 'invalid .python-version: expected major.minor'
state_dir="${XDG_DATA_HOME:-$HOME/.local/share}/codex-config-policy"
case "$state_dir" in
    /*) ;;
    *) fail 'XDG_DATA_HOME must be absolute' ;;
esac
mkdir -p "$state_dir"
state_dir=$(CDPATH='' cd -- "$state_dir" && pwd -P)
venv_dir="$state_dir/venv"
backup="$state_dir/venv.backup"
lock="$state_dir/setup.lock"
mkdir "$lock" 2>/dev/null || fail "setup is running or left a lock at $lock; see docs/codex.md for recovery"
rollback=false
cleanup() {
    result=$?
    trap - 0 HUP INT TERM
    if "$rollback" && { [ -e "$backup" ] || [ -L "$backup" ]; }; then
        if rm -rf -- "$venv_dir" && mv -- "$backup" "$venv_dir"; then
            echo 'codex-config: restored the previous venv' >&2
        else
            echo "codex-config: restore failed; preserve $backup and $venv_dir; lock retained at $lock" >&2
            exit 1
        fi
    fi
    if [ -e "$backup" ] || [ -L "$backup" ]; then
        echo "codex-config: backup remains at $backup; lock retained at $lock; see docs/codex.md" >&2
        exit 1
    fi
    rmdir "$lock" || exit 1
    exit "$result"
}
trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
[ ! -e "$backup" ] && [ ! -L "$backup" ] || fail "unfinished backup at $backup; see docs/codex.md for recovery"

# Keep runtime selection independent of the caller's activated environment.
unset VIRTUAL_ENV PYTHONHOME PYTHONPATH UV_PYTHON UV_PYTHON_PREFERENCE
unset UV_MANAGED_PYTHON UV_NO_MANAGED_PYTHON UV_PROJECT UV_WORKING_DIR UV_CONFIG_FILE
export UV_PYTHON_INSTALL_DIR="$state_dir/python"
export UV_PROJECT_ENVIRONMENT="$venv_dir"
python_probe='import os, sys
if sys.version_info < (3, 11):
    raise SystemExit("Python 3.11+ is required")
if sys.argv[1] and sys.argv[1] != "%s.%s" % sys.version_info[:2]:
    raise SystemExit("Python series differs from .python-version")
if sys.argv[2] == "venv" and sys.prefix == sys.base_prefix:
    raise SystemExit("expected a virtual environment")
print(os.path.realpath(getattr(sys, "_base_executable", sys.executable)))'
existing_base=''
has_venv=false
if [ -e "$venv_dir" ] || [ -L "$venv_dir" ]; then
    has_venv=true
    existing_base=$("$venv_dir/bin/python" -I -c "$python_probe" '' venv) || {
        "$upgrade" || fail 'venv Python cannot start; run setup.sh --upgrade-python'
    }
fi

if [ -n "$explicit_python" ]; then
    [ -x "$explicit_python" ] || fail 'Python executable is missing or not executable'
    python_base=$("$explicit_python" -I -c "$python_probe" '' base) || fail 'cannot use the selected Python 3.11+ executable'
    if "$has_venv"; then
        [ "$existing_base" = "$python_base" ] || fail 'venv uses a different Python; use a separate test environment or setup.sh --upgrade-python'
    fi
elif "$has_venv" && ! "$upgrade"; then
    case "$existing_base" in
        "$UV_PYTHON_INSTALL_DIR"/*) ;;
        *) fail 'venv uses an external Python; run setup.sh --upgrade-python to migrate' ;;
    esac
    python_base=$("$venv_dir/bin/python" -I -c "$python_probe" "$series" venv) ||
        fail 'venv Python differs from the configured series; run setup.sh --upgrade-python'
else
    if "$upgrade"; then
        uv python install --no-config --no-bin --upgrade "$series"
    else
        uv python install --no-config --no-bin "$series"
    fi
    python_path=$(uv python find --no-config --no-project --system --managed-python \
        --no-python-downloads --resolve-links "$series")
    python_base=$("$python_path" -I -c "$python_probe" "$series" base) || fail 'cannot start the managed Python'
    case "$python_base" in
        "$UV_PYTHON_INSTALL_DIR"/*) ;;
        *) fail 'uv selected a Python outside the dedicated installation directory' ;;
    esac
fi

if [ -n "$explicit_python" ]; then
    set -- --python "$python_base"
else
    # A patch request prevents uv from binding the venv to its moving minor link.
    python_version=$("$python_base" -I -c 'import sys; print("%s.%s.%s" % sys.version_info[:3])')
    set -- --managed-python --python "$python_version"
fi
if "$has_venv" && [ "$existing_base" != "$python_base" ]; then
    # Arm rollback before moving: a caught signal after mv must restore too.
    rollback=true
    mv -- "$venv_dir" "$backup"
fi
# Normal dependency updates belong to uv; only interpreter changes rebuild.
uv sync --project "$project_dir" --locked --no-python-downloads "$@"
actual_base=$("$venv_dir/bin/python" -I -c "$python_probe" '' venv) || fail 'venv Python cannot start after sync'
[ "$actual_base" = "$python_base" ] || fail 'venv uses a different Python after sync'
# main validates dependencies and a complete merge for every policy without
# reading live config. The vanilla wrapper always needs the default policy, so
# a missing file must fail here rather than at the next apply. The project path
# is consumed before main() runs so the merge CLI sees only the policy
# selection.
[ -f "$project_dir/policy.toml" ] || fail 'scripts/codex-config/policy.toml is missing'
for policy in "$project_dir"/policy*.toml; do
    "$venv_dir/bin/python" -I -B -c \
        'import sys; sys.path.insert(0, sys.argv.pop(1)); from merge import main; sys.exit(main())' \
        "$project_dir" --policy "$(basename "$policy")" </dev/null >/dev/null
done
rollback=false
if [ -e "$backup" ] || [ -L "$backup" ]; then
    rm -rf -- "$backup"
fi
echo 'codex-config: dependency environment ready'
