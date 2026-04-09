function __gw_clean
    set -l base (__detect_default_branch)
    or return 1

    # main worktree のブランチを除外（%(worktreepath) は main repo にも設定されるため）
    set -l main_wt_branch (git worktree list --porcelain | awk '$1=="branch"{sub(/refs\/heads\//, "", $2); print $2; exit}')

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

    for b in $branches
        __gw_rm $b
    end
end
