function __worktree_path_for_branch --argument-names branch
    git worktree list --porcelain | awk -v b="refs/heads/$branch" \
        '$1=="worktree"{path=substr($0,10)} $1=="branch"&&$2==b{print path; exit}'
end
