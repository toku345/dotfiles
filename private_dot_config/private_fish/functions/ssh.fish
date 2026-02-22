function ssh --wraps ssh --description "SSH with iTerm2 tab color indicator"
    if not set -q ITERM_SESSION_ID
        command ssh $argv
        return
    end

    # Set tab color to orange during SSH session
    echo -ne "\033]6;1;bg;red;brightness;255\a"
    echo -ne "\033]6;1;bg;green;brightness;150\a"
    echo -ne "\033]6;1;bg;blue;brightness;0\a"

    command ssh $argv
    set -l ssh_status $status

    # Reset tab color to default after disconnect
    echo -ne "\033]6;1;bg;*;default\a"

    return $ssh_status
end
