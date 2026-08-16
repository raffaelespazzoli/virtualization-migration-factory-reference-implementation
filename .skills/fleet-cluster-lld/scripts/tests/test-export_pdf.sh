#!/usr/bin/env bash
# Unit tests for export_pdf.sh
# These tests verify argument handling and error cases without requiring pandoc.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/export_pdf.sh"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL+1)); }

# Test: missing argument shows usage error
test_missing_arg() {
    if output=$("$SCRIPT" 2>&1); then
        fail "missing_arg" "expected non-zero exit"
    else
        if echo "$output" | grep -qi "usage\|input"; then
            pass "missing_arg"
        else
            fail "missing_arg" "no usage message in output"
        fi
    fi
}

# Test: nonexistent input file
test_nonexistent_input() {
    if output=$("$SCRIPT" "/tmp/nonexistent_lld_test_$$.md" 2>&1); then
        fail "nonexistent_input" "expected non-zero exit"
    else
        pass "nonexistent_input"
    fi
}

# Test: script is executable
test_executable() {
    if [[ -x "$SCRIPT" ]]; then
        pass "executable"
    else
        fail "executable" "script is not executable"
    fi
}

test_executable
test_missing_arg
test_nonexistent_input

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
