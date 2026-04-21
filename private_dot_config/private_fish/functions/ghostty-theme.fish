function ghostty-theme --description 'Apply a Ghostty bundled theme to the current surface via OSC sequences'
    set -l themes_dir
    if set -q GHOSTTY_THEMES_DIR
        set themes_dir $GHOSTTY_THEMES_DIR
    else
        set themes_dir /Applications/Ghostty.app/Contents/Resources/ghostty/themes
    end

    if not test -d $themes_dir
        echo "ghostty-theme: themes directory not found: $themes_dir" >&2
        return 1
    end

    set -l theme_name
    if set -q argv[1]; and test -n "$argv[1]"
        set theme_name $argv[1]
    else
        # fzf expands {} to the current item with shell-safe quoting; passing
        # it as a positional argument to `fish -c` keeps theme names with
        # spaces intact via $argv[1].
        # `command ls -1 --` bypasses fish's embedded `ls` function and any
        # user override (eza / lsd / custom wrappers) that could inject colors
        # or icons into fzf's input.
        set theme_name (command ls -1 -- $themes_dir | fzf --layout=reverse \
            --preview "fish -c '__ghostty_theme_preview \"$themes_dir/\$argv[1]\"' {}" \
            --preview-window right:50%)
        set -l picker_status $pipestatus
        if test $picker_status[1] -ne 0
            echo "ghostty-theme: failed to enumerate themes from $themes_dir" >&2
            return $picker_status[1]
        end
        set -l fzf_status $picker_status[2]
        switch $fzf_status
            case 0
                # selection made; fall through
            case 1 130
                # no match / cancelled (Esc/Ctrl-C)
                return 0
            case '*'
                echo "ghostty-theme: fzf exited with status $fzf_status" >&2
                return $fzf_status
        end
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

    echo "ghostty-theme: applied '$theme_name'"
end
