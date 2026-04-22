function __ghostty_theme_complete
    # No ghostty on PATH → no completions, and no fish "Unknown command"
    # noise on every Tab press. `ghostty-theme` itself fails loud when invoked.
    command -q ghostty; or return
    # ghostty prints `error: SentryInitFailed` to stderr on every invocation
    # (Ghostty 1.3.x), so silencing stderr is required to avoid spamming the
    # terminal on every Tab press. To keep failures from being silent, capture
    # stdout and check $pipestatus[1] — emit no candidates on non-zero ghostty
    # exit rather than half-parsed output.
    set -l themes (command ghostty +list-themes --plain 2>/dev/null \
        | string replace -r ' \((resources|user)\)$' '')
    test $pipestatus[1] -eq 0; or return
    printf '%s\n' $themes
end

complete -c ghostty-theme -f -a "(__ghostty_theme_complete)"
