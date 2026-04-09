function __gw_clean
    set -l force_flag
    for arg in $argv
        switch $arg
            case --force
                set force_flag --force
            case '-*'
                echo "Error: unknown option '$arg'" >&2
                return 1
            case '*'
                echo "Error: unexpected argument '$arg'" >&2
                return 1
        end
    end

    set -l base (__detect_default_branch)
    or return 1

    # main worktree のブランチを除外（%(worktreepath) は main repo にも設定されるため）
    # detached HEAD 時は branch 行がないため、最初の worktree ブロック（空行まで）のみ参照する
    set -l main_wt_branch (git worktree list --porcelain | awk '!NF{exit} $1=="branch"{sub(/refs\/heads\//, "", $2); print $2; exit}')

    set -l branches (git for-each-ref \
        --merged="$base" \
        --format='%(if)%(worktreepath)%(then)%(refname:short)%(end)' \
        refs/heads/ | string match -rv '^$' | string match -v -- $base | string match -v -- "$main_wt_branch")

    if test (count $branches) -eq 0
        echo "No merged worktree branches to clean." >&2
        return 0
    end

    echo "Merged worktree branches:" >&2
    for b in $branches
        echo "  $b" >&2
    end

    read -l -P "Delete these worktrees and branches? [y/N] " confirm
    string match -qir '^y' -- "$confirm"; or return 0

    set -l has_error 0
    for b in $branches
        __gw_rm $b $force_flag
        or set has_error 1
    end
    return $has_error
end
