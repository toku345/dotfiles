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

    # -c <branch> <base> → create new branch from base (no upstream)
    if test -n "$base"
        git fetch origin; or echo "Warning: git fetch origin failed; using local refs" >&2
        # Verify branch doesn't already exist (locally OR on remote)
        if git rev-parse --verify --quiet "refs/heads/$branch" >/dev/null
            or git rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null
            echo "Error: branch '$branch' already exists. Use 'gw -c $branch' without base." >&2
            return 1
        end
        set -l sha (__gw_resolve_base $base)
        or return 1
        __gw_add $branch -b $branch --no-track $sha
        return $status
    end

    # -c <branch> with an existing local branch
    if git rev-parse --verify --quiet "refs/heads/$branch" >/dev/null
        __gw_add $branch $branch
        return $status
    end

    # -c <branch> → remote-only branch, tracked as origin/<branch>
    git fetch origin; or echo "Warning: git fetch origin failed; using local refs" >&2
    if not git rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null
        echo "Error: branch '$branch' not found locally or on origin" >&2
        return 1
    end
    __gw_add $branch -b $branch --track origin/$branch
end
