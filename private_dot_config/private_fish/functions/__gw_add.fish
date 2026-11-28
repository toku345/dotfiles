function __gw_add --description 'git worktree add at <main repo>-worktrees/<sanitized branch>, then cd'
    # Usage: __gw_add <branch> <git worktree add options/commit-ish...>
    set -l branch $argv[1]
    set -l main_repo (git worktree list --porcelain | awk 'NR==1{print substr($0,10); exit}')
    if test -z "$main_repo"
        echo "Error: failed to determine main repo path" >&2
        return 1
    end

    # Same directory naming as git-gtr, so existing worktree paths stay valid
    set -l name (string replace -ra '[/\\\\ :*?"<>|#]' - -- $branch | string trim -c -)
    if test -z "$name"; or test "$name" = .; or test "$name" = ..
        echo "Error: cannot derive a worktree directory name from '$branch'" >&2
        return 1
    end
    set -l wt_path "$main_repo-worktrees/$name"
    if test -e "$wt_path"
        echo "Error: '$wt_path' already exists" >&2
        return 1
    end

    if not git worktree add "$wt_path" $argv[2..]
        # A failing post-checkout hook makes `git worktree add` exit non-zero
        # after the worktree is created. Detect that by path + branch.
        set -l created (__worktree_path_for_branch $branch)
        if test "$created" = "$wt_path"
            echo "Error: worktree '$wt_path' was created, but its post-checkout hook failed." >&2
            echo "  Fix the cause, then re-run it from inside the worktree:" >&2
            echo "    git hook run post-checkout -- 0000000000000000000000000000000000000000 (git rev-parse HEAD) 1" >&2
            cd "$wt_path"
        end
        return 1
    end

    cd "$wt_path"
    or begin; echo "Error: failed to cd to '$wt_path'" >&2; return 1; end
end
