function __gw_checkout
    set -l branch $argv[1]
    test -n "$branch"; or begin
        echo "Usage: gw -c <branch> [<base>]" >&2
        return 1
    end
    set -l base $argv[2]

    # Branch already has a worktree → just cd
    set -l existing_path (__worktree_path_for_branch $branch)
    if test -n "$existing_path"
        cd "$existing_path"
        return $status
    end

    # -c <branch> <base> → create new branch from base
    if test -n "$base"
        # Verify branch doesn't already exist (locally OR on remote)
        if git rev-parse --verify $branch >/dev/null 2>&1
            or git rev-parse --verify origin/$branch >/dev/null 2>&1
            echo "Error: branch '$branch' already exists. Use 'gw -c $branch' without base." >&2
            return 1
        end
        git gtr new $branch --from $base --track none --yes
    else
        # -c <branch> → use existing local/remote branch
        if not git rev-parse --verify $branch >/dev/null 2>&1
            and not git rev-parse --verify origin/$branch >/dev/null 2>&1
            echo "Error: branch '$branch' not found locally or on origin" >&2
            return 1
        end
        git gtr new $branch --yes
    end

    or return 1

    set -l d (git gtr go $branch)
    test $status -eq 0; and test -n "$d"; and cd "$d"
    or begin
        echo "Error: failed to navigate to worktree for '$branch'" >&2
        return 1
    end
end
