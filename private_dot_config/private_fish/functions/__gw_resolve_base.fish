function __gw_resolve_base --argument-names base --description 'Resolve <base> (local ref, then origin/<base>) to a commit SHA'
    # Resolving to a SHA keeps `git worktree add -b` from guessing a remote branch
    git rev-parse --verify --quiet "$base^{commit}"
    and return 0
    git rev-parse --verify --quiet "origin/$base^{commit}"
    and return 0
    echo "Error: base '$base' not found locally or on origin" >&2
    return 1
end
