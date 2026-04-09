function __gw_rm
    set -l branch
    set -l force_flag
    for arg in $argv
        switch $arg
            case --force
                set force_flag --force
            case '-*'
                echo "Error: unknown option '$arg'" >&2
                return 1
            case '*'
                if test -n "$branch"
                    echo "Error: too many arguments (expected one branch)" >&2
                    return 1
                end
                set branch $arg
        end
    end
    test -n "$branch"; or begin
        echo "Usage: gw rm <branch> [--force]" >&2
        return 1
    end

    # 対象ブランチに worktree が存在するか確認
    set -l wt_path (__worktree_path_for_branch $branch)
    if test -z "$wt_path"
        echo "Error: no worktree found for branch '$branch'" >&2
        return 1
    end

    # git worktree remove は削除対象の worktree 内から実行すると失敗するため、先に退避する
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

    git gtr rm $branch --delete-branch --yes $force_flag

    # git gtr rm は失敗時も exit 0 を返すため、worktree の残存で判定
    set -l remaining (__worktree_path_for_branch $branch)
    if test -n "$remaining"
        echo "Error: failed to remove worktree for branch '$branch'" >&2
        return 1
    end
end
