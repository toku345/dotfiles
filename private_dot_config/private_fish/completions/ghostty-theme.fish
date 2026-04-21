switch (uname)
case Darwin
    set -l themes_dir /Applications/Ghostty.app/Contents/Resources/ghostty/themes
    if test -d $themes_dir
        complete -c ghostty-theme -f -a "(ls $themes_dir)"
    end
end
