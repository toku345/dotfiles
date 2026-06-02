#!/bin/sh

set -eu

required_major=11
required_minor=10
required_patch=0
required_cooldown_days=7

if ! command -v npm >/dev/null 2>&1; then
    exit 0
fi

npm_version=$(npm --version) || {
    printf '%s\n' "error: npm is installed, but 'npm --version' failed" >&2
    exit 1
}

parse_npm_version() {
    version=$1

    old_ifs=$IFS
    IFS=.
    # shellcheck disable=SC2086
    set -- $version
    IFS=$old_ifs

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

validate_before_window() {
    before_value=$1

    if ! command -v node >/dev/null 2>&1; then
        printf '%s\n' "error: npm is installed, but node is not available for npm cooldown validation" >&2
        return 1
    fi

    node -e '
const before = Date.parse(process.argv[1]);
const requiredDays = Number(process.argv[2]);
if (!Number.isFinite(before) || !Number.isFinite(requiredDays)) {
  process.exit(2);
}
const ageDays = (Date.now() - before) / 86400000;
process.exit(ageDays >= requiredDays - 0.25 && ageDays <= requiredDays + 0.25 ? 0 : 1);
' "$before_value" "$required_cooldown_days"
}

verify_effective_cooldown() {
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/npm-cooldown-check.XXXXXX") || {
        printf '%s\n' "error: cannot create temporary directory for npm cooldown validation" >&2
        return 1
    }
    trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM

    effective_min_release_age=$(cd "$tmpdir" && npm config get min-release-age) || {
        printf '%s\n' "error: cannot read effective npm min-release-age" >&2
        return 1
    }
    effective_before=$(cd "$tmpdir" && npm config get before) || {
        printf '%s\n' "error: cannot read effective npm before setting" >&2
        return 1
    }

    case "$effective_before" in
        "" | null | undefined)
            if [ "$effective_min_release_age" = "$required_cooldown_days" ]; then
                return 0
            fi
            ;;
        *)
            if validate_before_window "$effective_before"; then
                return 0
            fi
            ;;
    esac

    cat >&2 <<MSG

========================================
 npm cooldown not effective (chezmoi apply blocked)
========================================

~/.npmrc should enforce min-release-age=$required_cooldown_days by default, but npm reports:
  min-release-age=$effective_min_release_age
  before=$effective_before

Remove any default npm config override that disables or replaces the cooldown,
then re-run:
  chezmoi apply

Per-command recovery overrides such as --min-release-age=0 should be used only
in an isolated throwaway workspace, not as default shell or project config.

========================================

MSG
    return 1
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

verify_effective_cooldown
