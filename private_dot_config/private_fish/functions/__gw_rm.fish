function __gw_rm
    set -l branch $argv[1]
    test -n "$branch"; or begin
        echo "Usage: gw rm <branch>" >&2
        return 1
    end

    # worktree 内にいる場合、main repo に cd してから削除
    set -l wt_path (__worktree_path_for_branch $branch)
    if test -n "$wt_path"
        set -l current (pwd -P)
        if test "$current" = "$wt_path"; or string match -q "$wt_path/*" -- "$current"
            set -l main_repo (git worktree list --porcelain | awk 'NR==1{print substr($0,10); exit}')
            if test -z "$main_repo"
                echo "Error: failed to determine main repo path" >&2
                return 1
            end
            cd "$main_repo"
            or begin; echo "Error: failed to cd to main repo" >&2; return 1; end
        end
    end

    git gtr rm $branch --delete-branch --yes
end
