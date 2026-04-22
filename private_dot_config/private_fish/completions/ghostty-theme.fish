function __ghostty_theme_complete
    # Strip the trailing " (resources)" / " (user)" suffix that
    # `ghostty +list-themes --plain` emits, leaving the bare theme name.
    command ghostty +list-themes --plain 2>/dev/null \
        | string replace -r ' \((resources|user)\)$' ''
end

complete -c ghostty-theme -f -a "(__ghostty_theme_complete)"
