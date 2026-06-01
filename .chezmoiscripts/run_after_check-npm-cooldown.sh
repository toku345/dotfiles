#!/bin/sh

set -eu

required_major=11
required_minor=10
required_patch=0

if ! command -v npm >/dev/null 2>&1; then
    exit 0
fi

npm_version=$(npm --version) || {
    printf '%s\n' "error: npm is installed, but 'npm --version' failed" >&2
    exit 1
}

parse_npm_version() {
    version=$1

    IFS=.
    # shellcheck disable=SC2086
    set -- $version
    IFS=' 	
'

    major=${1:-}
    minor=${2:-}
    patch=${3:-}
    patch=${patch%%[!0123456789]*}

    case "$major:$minor:$patch" in
        *[!0123456789:]* | :* | *:: | *:)
            return 1
            ;;
    esac

    printf '%s %s %s\n' "$major" "$minor" "$patch"
}

parsed=$(parse_npm_version "$npm_version") || {
    printf '%s\n' "error: cannot parse npm version '$npm_version'" >&2
    printf '%s\n' "npm >= 11.10.0 is required so ~/.npmrc min-release-age is enforced." >&2
    exit 1
}

major=${parsed%% *}
rest=${parsed#* }
minor=${rest%% *}
patch=${rest#* }

version_ok=0
if [ "$major" -gt "$required_major" ]; then
    version_ok=1
elif [ "$major" -eq "$required_major" ]; then
    if [ "$minor" -gt "$required_minor" ]; then
        version_ok=1
    elif [ "$minor" -eq "$required_minor" ] && [ "$patch" -ge "$required_patch" ]; then
        version_ok=1
    fi
fi

if [ "$version_ok" -ne 1 ]; then
    cat >&2 <<MSG

========================================
 npm cooldown not enforced (chezmoi apply blocked)
========================================

~/.npmrc sets min-release-age=7, but this host has npm $npm_version.
npm >= 11.10.0 is required for the cooldown to be enforced.

Upgrade npm, then re-run:
  chezmoi apply

========================================

MSG
    exit 1
fi
