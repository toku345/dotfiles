function __ghostty_theme_preview --description 'Render a Ghostty theme file as an ANSI truecolor preview (used by ghostty-theme fzf picker)'
    set -l file $argv[1]

    if not test -f $file
        echo "preview: file not found: $file" >&2
        return 1
    end

    while read -l line
        set -l m (string match -rg '^\s*palette\s*=\s*(\d+)\s*=\s*#([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})\s*$' -- $line)
        if test $status -eq 0
            set -l idx $m[1]
            set -l rh $m[2]
            set -l gh $m[3]
            set -l bh $m[4]
            printf 'palette %2d  \e[48;2;%d;%d;%dm      \e[0m  #%s%s%s\n' \
                $idx (math 0x$rh) (math 0x$gh) (math 0x$bh) $rh $gh $bh
            continue
        end

        # cursor-text is rendered even though it has no OSC counterpart, so the
        # user can see every theme value at a glance.
        for key in background foreground cursor-color cursor-text selection-background selection-foreground
            set -l n (string match -rg '^\s*'"$key"'\s*=\s*#([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})\s*$' -- $line)
            if test $status -eq 0
                set -l rh $n[1]
                set -l gh $n[2]
                set -l bh $n[3]
                printf '%-20s  \e[48;2;%d;%d;%dm      \e[0m  #%s%s%s\n' \
                    $key (math 0x$rh) (math 0x$gh) (math 0x$bh) $rh $gh $bh
                break
            end
        end
    end <$file
end
