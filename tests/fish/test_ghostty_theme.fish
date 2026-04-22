set -l tests_dir (cd (dirname (status filename)); and pwd)
set -l snap_dir $tests_dir/snapshots/ghostty-theme
set -l scratch_dir $tests_dir/.scratch
mkdir -p $scratch_dir

# 1: complete theme -> OSC snapshot
set -l out (ghostty-theme TestDark | string collect)
set -l rc $pipestatus[1]
assert_status "TestDark rc" $rc 0
assert_snapshot "complete TestDark OSC" "$out" $snap_dir/TestDark.expected

# 2: palette-only theme
set -l out (ghostty-theme TestMinimal | string collect)
set -l rc $pipestatus[1]
assert_status "TestMinimal rc" $rc 0
assert_snapshot "palette-only TestMinimal OSC" "$out" $snap_dir/TestMinimal.expected

# 3: mixed theme (comments, whitespace, invalid hex, mixed case)
set -l out (ghostty-theme TestMixed | string collect)
set -l rc $pipestatus[1]
assert_status "TestMixed rc" $rc 0
assert_snapshot "TestMixed OSC" "$out" $snap_dir/TestMixed.expected

# 4: applied message includes theme name
set -l out (ghostty-theme TestDark | string collect)
set -l rc $pipestatus[1]
assert_status "applied message rc" $rc 0
assert_match "applied message present" "$out" "applied 'TestDark'"

# 5: missing theme name -> exit 1 + stderr mentions not found
set -l stderr (ghostty-theme NoSuch 2>&1 >/dev/null | string collect)
set -l rc $pipestatus[1]
assert_status "missing theme returns 1" $rc 1
assert_match "missing theme stderr message" "$stderr" "theme 'NoSuch' not found in"

# 6: invalid GHOSTTY_THEMES_DIR -> exit 1 + stderr mentions not found
set -l err_file $scratch_dir/err-6.txt
GHOSTTY_THEMES_DIR=/nonexistent fish --no-config -c "
    source $tests_dir/../../private_dot_config/private_fish/functions/ghostty-theme.fish
    ghostty-theme TestDark
" 2>$err_file >/dev/null
set -l rc $status
set -l stderr (cat $err_file | string collect)
rm -f $err_file
assert_status "bad themes dir returns 1" $rc 1
assert_match "bad themes dir stderr message" "$stderr" "themes directory not found: /nonexistent"

# 7: empty GHOSTTY_THEMES_DIR (defined but empty) -> exit 1
set -l err_file $scratch_dir/err-7.txt
GHOSTTY_THEMES_DIR= fish --no-config -c "
    source $tests_dir/../../private_dot_config/private_fish/functions/ghostty-theme.fish
    ghostty-theme TestDark
" 2>$err_file >/dev/null
set -l rc $status
set -l stderr (cat $err_file | string collect)
rm -f $err_file
assert_status "empty themes dir returns 1" $rc 1
assert_match "empty themes dir stderr message" "$stderr" "themes directory not found:"

# 8: theme name with spaces
set -l out (ghostty-theme "Test Spaces" | string collect)
set -l rc $pipestatus[1]
assert_status "Test Spaces rc" $rc 0
assert_snapshot "Test Spaces OSC" "$out" $snap_dir/TestSpaces.expected

# 9: invalid 5-hex line in TestMixed should be skipped (covered by case 3 snapshot).
#    Additionally verify the output does NOT contain the bad palette index 2.
set -l out (ghostty-theme TestMixed | string collect)
set -l rc $pipestatus[1]
assert_status "5-hex skip rc" $rc 0
assert_not_match "5-hex palette=2 skipped" "$out" '\e\]4;2;#'

# 16: fzf stub -- selection value hands off via argv
set -l log_file $scratch_dir/fzf-stdin-16.log
set -gx FAKE_FZF_SELECT TestDark
set -gx FAKE_FZF_EXIT 0
set -gx FAKE_FZF_STDIN_LOG $log_file
set -l out (ghostty-theme | string collect)
set -l rc $pipestatus[1]
assert_status "fzf stub select exit 0" $rc 0
assert_match "fzf stub select applied msg" "$out" "applied 'TestDark'"
rm -f $log_file
set -e FAKE_FZF_SELECT FAKE_FZF_EXIT FAKE_FZF_STDIN_LOG

# 17: fzf stub -- cancel (exit 130) propagates as return 0, no OSC
set -gx FAKE_FZF_EXIT 130
set -l out (ghostty-theme | string collect)
set -l rc $pipestatus[1]
assert_status "fzf stub cancel exit 0" $rc 0
assert_equal "fzf stub cancel empty output" "$out" ""
set -e FAKE_FZF_EXIT

# 18: command ls guard -- poison `ls` function; stub stdin must still see raw filenames
set -l log_file $scratch_dir/fzf-stdin-18.log
set -gx FAKE_FZF_SELECT TestDark
set -gx FAKE_FZF_EXIT 0
set -gx FAKE_FZF_STDIN_LOG $log_file
function ls
    echo POISONED
end
ghostty-theme >/dev/null
set -l rc $status
functions --erase ls
set -l logged (cat $log_file | string collect)
rm -f $log_file
set -e FAKE_FZF_SELECT FAKE_FZF_EXIT FAKE_FZF_STDIN_LOG
assert_status "command ls guard rc" $rc 0
assert_match "command ls guard -- fixture name in stdin" "$logged" "TestDark"
assert_not_match "command ls guard -- POISONED not in stdin" "$logged" "POISONED"
