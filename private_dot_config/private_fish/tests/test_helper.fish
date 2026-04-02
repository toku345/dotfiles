# Minimal Fish shell test harness
set -g __test_pass 0
set -g __test_fail 0
set -g __test_errors

function assert_equal --description 'Assert two values are equal'
    set -l label $argv[1]
    set -l expected $argv[2]
    set -l actual $argv[3]

    if test "$expected" = "$actual"
        set -g __test_pass (math $__test_pass + 1)
    else
        set -g __test_fail (math $__test_fail + 1)
        set -a __test_errors "FAIL: $label: expected '$expected', got '$actual'"
    end
end

function assert_status --description 'Assert exit status'
    set -l label $argv[1]
    set -l expected $argv[2]
    set -l actual $argv[3]

    if test "$expected" = "$actual"
        set -g __test_pass (math $__test_pass + 1)
    else
        set -g __test_fail (math $__test_fail + 1)
        set -a __test_errors "FAIL: $label: expected status $expected, got $actual"
    end
end

function test_report --description 'Print results and exit with appropriate status'
    echo "Results: $__test_pass passed, $__test_fail failed"
    if test $__test_fail -gt 0
        echo ""
        for err in $__test_errors
            echo "  $err"
        end
        return 1
    end
    return 0
end
