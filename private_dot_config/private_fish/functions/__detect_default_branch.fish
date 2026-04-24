function __detect_default_branch
    set -l ref (git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null)
    and begin
        set -l branch (string replace 'refs/remotes/origin/' '' $ref)
        git rev-parse --verify $branch >/dev/null 2>&1
        and echo $branch
        and return
    end

    for candidate in main master trunk
        if git rev-parse --verify $candidate >/dev/null 2>&1
            echo $candidate
            return
        end
    end

    echo "Error: default branch を検出できません" >&2
    return 1
end
