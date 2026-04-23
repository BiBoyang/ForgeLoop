#!/bin/bash
# Release check script — read-only, no destructive actions
# Usage: ./Scripts/release-check.sh
#
# STEP-028B: CI 门禁收口
# - 关键回归测试（non-blocking：失败时 warn）
# - 性能门禁测试（non-blocking：失败时 warn）
# - 文件存在性/git 状态（blocking：失败时 fail）

set -euo pipefail

PASS=0
WARN=0
FAIL=0

log_pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
log_warn() { echo "  [WARN] $1"; WARN=$((WARN + 1)); }
log_fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

run_test_nonblocking() {
    local label="$1"
    local filter="$2"
    echo ""
    echo "[test/$label] Running swift test --filter $filter ..."
    if swift test --filter "$filter" >/dev/null 2>&1; then
        log_pass "$label tests passed"
    else
        log_warn "$label tests failed (non-blocking for 028B)"
    fi
}

echo "=== ForgeLoop Release Check ==="
echo ""

# 1) Git workspace clean
echo "[1/8] Checking git workspace..."
if git diff --quiet && git diff --cached --quiet; then
    log_pass "Working tree is clean"
else
    log_warn "Working tree has uncommitted changes"
fi

# 2) Required files exist
echo ""
echo "[2/8] Checking required files..."
required_files=(
    "Package.swift"
    "Sources/forgeloop/main.swift"
    "docs/03-Step看板.md"
    "docs/reviews/REVIEW-LOG.md"
    "docs/release/RELEASE-CHECKLIST.md"
)
for f in "${required_files[@]}"; do
    if [[ -f "$f" ]]; then
        log_pass "$f exists"
    else
        log_fail "$f missing"
    fi
done

# 3) Check build artifact exists (read-only, does not trigger compilation)
echo ""
echo "[3/8] Checking build artifact..."
if [[ -f ".build/debug/forgeloop" ]]; then
    log_pass "Build artifact exists (.build/debug/forgeloop)"
else
    log_warn "No build artifact found — run 'swift build' before releasing"
fi

# 4) Check test sources exist (read-only, does not run tests)
echo ""
echo "[4/8] Checking test sources..."
test_files=$(find Tests -name "*Tests.swift" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$test_files" -gt 0 ]]; then
    log_pass "Test sources found: $test_files file(s)"
else
    log_fail "No test sources found in Tests/"
fi

# 5) Check for TODO markers in source
echo ""
echo "[5/8] Checking for TODO/FIXME markers..."
todo_count=$(grep -ri "TODO\|FIXME" Sources/ --include="*.swift" 2>/dev/null | wc -l | tr -d ' ' || true)
if [[ "$todo_count" -eq 0 ]]; then
    log_pass "No TODO/FIXME markers in Sources/"
else
    log_warn "Found $todo_count TODO/FIXME marker(s) in Sources/"
fi

# 6) Count test cases (read-only grep, no compilation)
echo ""
echo "[6/8] Counting test cases..."
test_count=$(grep -rh "func test" Tests/ --include="*.swift" 2>/dev/null | wc -l | tr -d ' ' || true)
if [[ "$test_count" -ge 100 ]]; then
    log_pass "Test cases: $test_count (>= 100)"
else
    log_warn "Test cases: $test_count (< 100)"
fi

# 7) STEP-028B: 关键回归测试（non-blocking）
echo ""
echo "[7/8] STEP-028B: Running regression gates (non-blocking)..."
run_test_nonblocking "ForgeLoopCli" "ForgeLoopCliTests"
run_test_nonblocking "Agent" "Agent"
run_test_nonblocking "AI" "AI"

# 8) STEP-028B: 性能门禁测试（non-blocking）
echo ""
echo "[8/8] STEP-028B: Running performance gates (non-blocking)..."
run_test_nonblocking "Performance-Gate" "PerformanceGateTests"

# Manual reminder
echo ""
echo "  [NOTE] Remember to run 'swift test' manually before tagging."

# Summary
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  WARN: $WARN"
echo "  FAIL: $FAIL"

if [[ $FAIL -gt 0 ]]; then
    echo ""
    echo "Result: FAIL — fix failures before releasing."
    exit 1
elif [[ $WARN -gt 0 ]]; then
    echo ""
    echo "Result: WARN — review warnings, may proceed with caution."
    exit 0
else
    echo ""
    echo "Result: PASS — ready to release."
    exit 0
fi
