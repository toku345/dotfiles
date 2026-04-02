function __gb_parse_branch_line --description 'Parse git branch output line → marker_type branch_name'
    set -l line $argv[1]
    test -n "$line"; or return 1

    set -l raw_marker (string sub -l 1 -- "$line")

    # git branch format: pos 1 = marker (*/+/space), pos 2 = space, pos 3+ = branch name
    # Fish switch case evaluates top-down; '*' glob acts as fallback catching literal '*'
    switch "$raw_marker"
        case '+'
            echo worktree
        case ' '
            echo regular
        case '*'
            echo current
    end
    echo (string sub -s 3 -- "$line")
end
