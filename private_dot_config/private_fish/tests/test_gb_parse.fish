#!/usr/bin/env fish
set -l test_dir (status dirname)
source $test_dir/test_helper.fish
source $test_dir/../functions/__gb_parse_branch_line.fish

# --- current branch ---
set -l r (__gb_parse_branch_line '* main')
assert_equal 'current: marker' current $r[1]
assert_equal 'current: name' main $r[2]

# --- worktree branch ---
set -l r (__gb_parse_branch_line '+ feature-wt')
assert_equal 'worktree: marker' worktree $r[1]
assert_equal 'worktree: name' feature-wt $r[2]

# --- regular branch ---
set -l r (__gb_parse_branch_line '  develop')
assert_equal 'regular: marker' regular $r[1]
assert_equal 'regular: name' develop $r[2]

# --- P3 regression: branch name starting with + ---
set -l r (__gb_parse_branch_line '  +plus-branch')
assert_equal 'P3 +branch: marker' regular $r[1]
assert_equal 'P3 +branch: name' +plus-branch $r[2]

# --- branch name starting with * ---
set -l r (__gb_parse_branch_line '  *star-branch')
assert_equal '*branch: marker' regular $r[1]
assert_equal '*branch: name' '*star-branch' $r[2]

# --- worktree branch whose name starts with + ---
set -l r (__gb_parse_branch_line '+ +weird-wt')
assert_equal 'wt +name: marker' worktree $r[1]
assert_equal 'wt +name: name' +weird-wt $r[2]

# --- feature branch with slashes ---
set -l r (__gb_parse_branch_line '  feat/gb-worktree-support')
assert_equal 'slash: marker' regular $r[1]
assert_equal 'slash: name' feat/gb-worktree-support $r[2]

# --- empty input ---
__gb_parse_branch_line ''
assert_status 'empty: returns 1' 1 $status

test_report
