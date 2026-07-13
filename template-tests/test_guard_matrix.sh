#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=template-tests/lib.sh disable=SC1091
source template-tests/lib.sh

WORKFLOW=.github/workflows/guard-base-branch.yml
SCRIPT=scripts/check-base-branch.sh

# Exercises the SAME script the workflow calls — not a copy of the case statement.
check() { # <head_ref> <base_ref>
  "$SCRIPT" "$1" "$2" >/dev/null 2>&1
}

assert_pass() {
  if check "$1" "$2"; then pass "$1 -> $2 PASS"; else fail "$1 -> $2 should PASS"; fi
}

assert_fail() {
  if check "$1" "$2"; then fail "$1 -> $2 should FAIL"; else pass "$1 -> $2 FAIL (as expected)"; fi
}

echo "guard-base-branch: base matrix"

assert_pass feat/x dev
assert_pass fix/x dev
assert_pass docs/x dev
assert_pass chore/x dev
assert_pass ci/x dev
assert_pass dependabot/npm/foo-1.2.3 dev
assert_pass dev staging
assert_pass staging main

assert_fail feat/x main
assert_fail feat/x staging
assert_fail dev main
assert_fail staging dev
assert_fail wip/x dev
assert_fail randomname dev

echo "guard-base-branch: job id"
if grep -A1 '^jobs:' "$WORKFLOW" | tail -1 | grep -q '^  guard-base-branch:$'; then
  pass "jobs key is literally guard-base-branch"
else
  fail "jobs key must be literally 'guard-base-branch'"
fi

finish
