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
#   ONLY_SUITES              space-separated suites to run instead of all of them (for a quick check)
set -u
cd "$(dirname "$0")/.."

TIMEOUT="${SUITE_TIMEOUT:-120}"
EXPECTED="${EXPECTED_FAILING_SUITES:-}"

swift build --build-tests || exit 2

# Suite names come from the test runner itself ("Module.Suite/test()").
SUITES="$(swift test list --skip-build 2>/dev/null | sed -E 's/^[^.]+\.([^/]+)\/.*/\1/' | sort -u)"
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

total_tests=0
suite_count=0
unexpected=""

for suite in $SUITES; do
    suite_count=$((suite_count + 1))
    out="$(perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" swift test --skip-build --filter "\\.${suite}/" 2>&1)"
    code=$?

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
        unexpected="$unexpected $suite"
    fi
done

echo
echo "$suite_count suites, $total_tests tests passed in passing suites"
if [ -n "$unexpected" ]; then
    echo "unexpected problems in:$unexpected"
    exit 1
fi
echo "all suites accounted for"
