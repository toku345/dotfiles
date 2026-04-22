#!/usr/bin/env fish
# Fish-native test runner for ghostty-theme.
# Spawns each test file in its own subprocess for function/variable isolation.

set -l repo_root (cd (dirname (status filename))/../..; and pwd)
set -l tests_dir $repo_root/tests/fish
set -l functions_dir $repo_root/private_dot_config/private_fish/functions

set -gx GHOSTTY_THEMES_DIR $tests_dir/fixtures/themes
set -gx PATH $tests_dir/bin $PATH

set -l test_files $tests_dir/test_*.fish
set -l failed 0

for test_file in $test_files
    set -l rel (string replace $repo_root/ "" $test_file)
    echo "=== $rel ==="

    # `--no-config` skips user config.fish so `fish_add_path` does not
    # reorder PATH and push our fzf stub behind the real binary.
    fish --no-config -c "
        set -gx PATH $tests_dir/bin \$PATH
        source $functions_dir/ghostty-theme.fish
        source $functions_dir/__ghostty_theme_preview.fish
        source $tests_dir/assert.fish
        source $test_file
        assert_summary
    "
    if test $status -ne 0
        set failed 1
    end
    echo ""
end

if test $failed -ne 0
    echo "one or more test files reported failures" >&2
    exit 1
end
echo "all tests passed"
