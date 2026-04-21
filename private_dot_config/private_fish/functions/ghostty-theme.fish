function ghostty-theme --description 'Apply a Ghostty bundled theme to the current surface via OSC sequences'
    set -l themes_dir /Applications/Ghostty.app/Contents/Resources/ghostty/themes

    if not test -d $themes_dir
        echo "ghostty-theme: themes directory not found: $themes_dir" >&2
        return 1
    end

    set -l theme_name
    if set -q argv[1]; and test -n "$argv[1]"
        set theme_name $argv[1]
    else
        # Pass the selected theme name as a positional argument (fzf escapes
        # {} for the outer shell; reaching it as $argv[1] inside `fish -c`
        # keeps names with spaces intact).
        set theme_name (ls $themes_dir | fzf --layout=reverse \
            --preview "fish -c '__ghostty_theme_preview \"$themes_dir/\$argv[1]\"' {}" \
            --preview-window right:50%)
        # Cancellation (Esc/Ctrl-C) returns nothing; exit quietly.
        test -n "$theme_name"; or return 0
    end

    set -l theme_file $themes_dir/$theme_name
    if not test -f $theme_file
        echo "ghostty-theme: theme '$theme_name' not found in $themes_dir" >&2
        return 1
    end

    while read -l line
        # palette = N=#RRGGBB -> OSC 4
        set -l m (string match -rg '^\s*palette\s*=\s*(\d+)\s*=\s*(#[0-9a-fA-F]{6})\s*$' -- $line)
        if test $status -eq 0
            printf '\e]4;%s;%s\e\\' $m[1] $m[2]
            continue
        end

        # key = #RRGGBB -> OSC <code>;#RRGGBB (for non-palette keys)
        for entry in 'background 11' 'foreground 10' 'cursor-color 12' 'selection-background 17' 'selection-foreground 19'
            set -l parts (string split ' ' -- $entry)
            set -l key $parts[1]
            set -l code $parts[2]
            set -l hex (string match -rg '^\s*'"$key"'\s*=\s*(#[0-9a-fA-F]{6})\s*$' -- $line)
            if test $status -eq 0
                printf '\e]%s;%s\e\\' $code $hex
                break
            end
        end
    end <$theme_file
end
