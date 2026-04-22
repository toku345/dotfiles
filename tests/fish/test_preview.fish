set -l tests_dir (cd (dirname (status filename)); and pwd)
set -l themes_dir $tests_dir/fixtures/themes
set -l snap_dir $tests_dir/snapshots/preview

# 10: full palette + non-palette keys preview
set -l out (__ghostty_theme_preview $themes_dir/TestDark | string collect)
set -l rc $pipestatus[1]
assert_status "TestDark preview rc" $rc 0
assert_snapshot "TestDark preview" "$out" $snap_dir/TestDark.expected

# 11: palette-only preview
set -l out (__ghostty_theme_preview $themes_dir/TestMinimal | string collect)
set -l rc $pipestatus[1]
assert_status "TestMinimal preview rc" $rc 0
assert_snapshot "TestMinimal preview" "$out" $snap_dir/TestMinimal.expected

# 12: cursor-text is rendered in preview (not applied via OSC but shown)
set -l out (__ghostty_theme_preview $themes_dir/TestDark | string collect)
set -l rc $pipestatus[1]
assert_status "cursor-text preview rc" $rc 0
assert_match "cursor-text line in preview" "$out" "cursor-text"

# 13: missing file -> exit 1 + stderr message
set -l stderr (__ghostty_theme_preview /nonexistent/path 2>&1 >/dev/null | string collect)
set -l rc $pipestatus[1]
assert_status "missing preview file returns 1" $rc 1
assert_match "missing preview stderr message" "$stderr" "preview: file not found:"

# 14: mixed-case hex (#AaBbCc) is accepted (covered by TestMixed snapshot)
set -l out (__ghostty_theme_preview $themes_dir/TestMixed | string collect)
set -l rc $pipestatus[1]
assert_status "TestMixed preview rc" $rc 0
assert_snapshot "TestMixed preview" "$out" $snap_dir/TestMixed.expected

# 15: leading/trailing whitespace tolerated (covered by TestMixed snapshot).
#     Additional check: the 5-hex palette=2 line must NOT appear in preview either.
assert_not_match "5-hex palette=2 skipped in preview" "$out" "palette  2"
