#!/bin/bash
# Runs every test suite in its own `swift test` process, with a time limit, and prints a summary.
#
# Why not a single `swift test`: the suites run in parallel inside one process, and several tests block their
# thread synchronously, which starves the cooperative thread pool the code under test also needs. A one-shot run can
# then stall for good. Each suite on its own finishes in seconds.
#
# Environment:
#   SUITE_TIMEOUT            seconds allowed per suite (default 120)
#   EXPECTED_FAILING_SUITES  space-separated suites known to fail: reported as such, and they do not fail the run.
#                            A suite listed here that starts passing is called out so it can be removed.
#   SKIPPED_SUITES          space-separated suites not run at all (listed in the summary), e.g. ones that need a
#                            window server on a machine that has none
#   ONLY_SUITES              space-separated suites to run instead of all of them (for a quick check)
set -u
cd "$(dirname "$0")/.."

TIMEOUT="${SUITE_TIMEOUT:-120}"
EXPECTED="${EXPECTED_FAILING_SUITES:-}"
SKIPPED="${SKIPPED_SUITES:-}"

swift build --build-tests || exit 2

# Suite names come from the test runner itself ("Module.Suite/test()").
ALL_TESTS="$(swift test list --skip-build 2>/dev/null)"
SUITES="$(printf '%s\n' "$ALL_TESTS" | sed -E 's/^[^.]+\.([^/]+)\/.*/\1/' | sort -u)"
if [ -n "${ONLY_SUITES:-}" ]; then
    selected=""
    for name in $ONLY_SUITES; do
        if printf '%s\n' "$SUITES" | grep -qx "$name"; then selected="$selected $name"; fi
    done
    SUITES="$selected"
fi
if [ -z "$(printf '%s' "$SUITES" | tr -d ' \n')" ]; then
    echo "error: no test suites were found" >&2
    exit 2
fi

is_expected() {
    for name in $EXPECTED; do
        [ "$name" = "$1" ] && return 0
    done
    return 1
}

is_skipped() {
    for name in $SKIPPED; do
        [ "$name" = "$1" ] && return 0
    done
    return 1
}

# Tests make throwaway UserDefaults suites (see TestDefaults.swift); each leaves a plist behind. They all start with
# "zenith.tests." and are removed here, after the writes cfprefsd still had pending for them.
clean_test_preferences() {
    sleep 2
    find "$HOME/Library/Preferences" -maxdepth 1 -name 'zenith.tests.*.plist' -delete 2>/dev/null
}
trap clean_test_preferences EXIT

total_tests=0
suite_count=0
skipped_count=0
unexpected=""

for suite in $SUITES; do
    if is_skipped "$suite"; then
        echo "skipped: $suite"
        skipped_count=$((skipped_count + 1))
        continue
    fi
    suite_count=$((suite_count + 1))
    # Output goes to a file, not a variable, so that what a hung suite printed before it was killed is not lost.
    log="$(mktemp)"
    perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" swift test --skip-build --filter "\\.${suite}/" >"$log" 2>&1
    code=$?
    out="$(cat "$log")"
    rm -f "$log"
    find "$HOME/Library/Preferences" -maxdepth 1 -name 'zenith.tests.*.plist' -delete 2>/dev/null

    if [ "$code" -eq 142 ]; then
        pkill -f swiftpm-testing-helper 2>/dev/null
        verdict="TIMEOUT"
        count=0
    else
        summary="$(printf '%s\n' "$out" | grep -E 'Test run with' | tail -1)"
        count="$(printf '%s\n' "$summary" | sed -nE 's/.*Test run with ([0-9]+) tests?.*/\1/p')"
        case "$summary" in
            *passed*) verdict="passed" ;;
            *failed*) verdict="FAILED" ;;
            *)        verdict="NO-RUN" ;;     # the filter matched nothing, or the process died
        esac
    fi

    if [ "$verdict" = "passed" ] && [ "${count:-0}" -gt 0 ]; then
        total_tests=$((total_tests + count))
        if is_expected "$suite"; then
            echo "note: $suite is listed as expected-failing but passed; remove it from EXPECTED_FAILING_SUITES"
        fi
        continue
    fi

    if is_expected "$suite"; then
        echo "expected failure: $suite ($verdict)"
    else
        echo "$verdict: $suite"
        printf '%s\n' "$out" | grep -E '✘ Test "|recorded an issue' | head -5 | sed 's/^/    /'
        if [ "$verdict" = "TIMEOUT" ]; then
            # The killed process printed nothing, so find the hanging test by running each one on its own.
            echo "    running each test of $suite alone (40 s each):"
            for test_id in $(printf '%s\n' "$ALL_TESTS" | grep "\\.${suite}/"); do
                one="$(perl -e 'alarm shift; exec @ARGV' 40 swift test --skip-build --filter "${test_id%()}" 2>&1)"
                one_code=$?
                if [ "$one_code" -eq 142 ]; then
                    echo "    | HANGS: $test_id"
                    pkill -f swiftpm-testing-helper 2>/dev/null
                else
                    echo "    | ok ($(printf '%s\n' "$one" | grep -E 'Test run with' | tail -1 | cut -c1-80)): $test_id"
                fi
            done
        fi
        if [ "$verdict" = "NO-RUN" ] || [ "$verdict" = "TIMEOUT" ]; then
            # No summary line: the process died or hung. What it printed last is the only clue to why.
            echo "    exit code $code; last output:"
            printf '%s\n' "$out" | tail -n 25 | cut -c1-240 | sed 's/^/    | /'
        fi
        unexpected="$unexpected $suite"
    fi
done

echo
echo "$suite_count suites run, $skipped_count skipped, $total_tests tests passed in passing suites"
if [ -n "$unexpected" ]; then
    echo "unexpected problems in:$unexpected"
    exit 1
fi
echo "all suites accounted for"
