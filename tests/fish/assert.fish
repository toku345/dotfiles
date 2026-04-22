set -g __assert_pass_count 0
set -g __assert_fail_count 0

function __assert_pass
    set __assert_pass_count (math $__assert_pass_count + 1)
    echo "[PASS] $argv[1]"
end

function __assert_fail
    set __assert_fail_count (math $__assert_fail_count + 1)
    echo "[FAIL] $argv[1]" >&2
    for line in $argv[2..]
        echo "    $line" >&2
    end
end

function assert_equal --description 'assert_equal <label> <actual> <expected>'
    set -l label $argv[1]
    set -l actual $argv[2]
    set -l expected $argv[3]
    if test "$actual" = "$expected"
        __assert_pass $label
    else
        __assert_fail $label "expected: $expected" "actual:   $actual"
    end
end

function assert_status --description 'assert_status <label> <actual> <expected>'
    set -l label $argv[1]
    set -l actual $argv[2]
    set -l expected $argv[3]
    if test "$actual" -eq "$expected"
        __assert_pass $label
    else
        __assert_fail $label "expected exit: $expected" "actual exit:   $actual"
    end
end

function assert_match --description 'assert_match <label> <haystack> <pattern>'
    set -l label $argv[1]
    set -l haystack $argv[2]
    set -l pattern $argv[3]
    if string match -q -r -- $pattern $haystack
        __assert_pass $label
    else
        __assert_fail $label "pattern:  $pattern" "haystack: $haystack"
    end
end

function assert_not_match --description 'assert_not_match <label> <haystack> <pattern>'
    set -l label $argv[1]
    set -l haystack $argv[2]
    set -l pattern $argv[3]
    if string match -q -r -- $pattern $haystack
        __assert_fail $label "should NOT match pattern: $pattern" "haystack: $haystack"
    else
        __assert_pass $label
    end
end

function assert_snapshot --description 'assert_snapshot <label> <actual> <snapshot_path>'
    set -l label $argv[1]
    set -l actual $argv[2]
    set -l snapshot_path $argv[3]

    if set -q UPDATE_SNAPSHOTS; and test -n "$UPDATE_SNAPSHOTS"
        mkdir -p (dirname $snapshot_path)
        printf '%s' $actual >$snapshot_path
        __assert_pass "$label (snapshot updated)"
        return
    end

    if not test -f $snapshot_path
        __assert_fail $label "snapshot missing: $snapshot_path" "run with UPDATE_SNAPSHOTS=1 to create"
        return
    end

    set -l diff_output (printf '%s' $actual | diff -u $snapshot_path - 2>&1)
    set -l diff_status $pipestatus[2]
    if test $diff_status -eq 0
        __assert_pass $label
    else
        __assert_fail $label "snapshot mismatch: $snapshot_path" $diff_output
    end
end

function assert_summary --description 'assert_summary — print totals and exit with failure count'
    set -l total (math $__assert_pass_count + $__assert_fail_count)
    echo "---"
    echo "$__assert_pass_count passed, $__assert_fail_count failed ($total total)"
    if test $__assert_fail_count -gt 0
        exit 1
    end
    exit 0
end
