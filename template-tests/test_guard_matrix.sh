#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=template-tests/lib.sh disable=SC1091
source template-tests/lib.sh

WORKFLOW=.github/workflows/checks.yml
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

echo "guard-base-branch: the guard's logic must come from the BASE branch, not the PR it judges"
# The workflow runs on pull_request, so a default checkout gives it the PR HEAD's tree — which
# means the PR supplies the very script that judges it. A PR from wip/x -> main that also
# rewrites check-base-branch.sh to `exit 0` would pass its own guard, and with
# required_approving_review_count: 0 nobody has to look at it. Checking out github.base_ref
# takes the script from the protected branch instead.
wf="$(cat "$WORKFLOW")"
# Anchored, and NOT via assert_match: that helper greps case-insensitively, and the step's own
# `BASE_REF: ${{ github.base_ref }}` env line matches a loose /ref: .../ pattern — which would
# make this assertion pass with a default checkout. It must match the checkout's `ref:` input.
if grep -qE '^ +ref: \$\{\{ *github\.base_ref *\}\}$' "$WORKFLOW"; then
  pass "actions/checkout takes ref: github.base_ref (guard logic comes from the protected branch)"
else
  fail "actions/checkout must set 'ref: \${{ github.base_ref }}' — otherwise the PR supplies the script that judges it"
fi
assert_match "declares a read-only permissions block" 'contents: *read' "$wf"

echo "guard-base-branch: it is a step of the merged 'checks' job"
# The guard used to be its own workflow and its own required context. It is now the first gate
# in checks.yml, because three single-step jobs billed 160 minutes a month to do 19 minutes of
# work. The context the ruleset requires is therefore 'checks', not 'guard-base-branch'.
if grep -A1 '^jobs:' "$WORKFLOW" | tail -1 | grep -q '^  checks:$'; then
  pass "jobs key is literally checks (the ruleset requires that exact context)"
else
  fail "jobs key must be literally 'checks' (the ruleset requires that exact context)"
fi
# The guard must still actually RUN, and from the trusted copy staged out of the base checkout.
# Pointing it at scripts/check-base-branch.sh in the workspace would silently hand the PR back
# the script that judges it — the exact hole the base checkout above exists to close.
if grep -qE '\$\{RUNNER_TEMP\}/trusted-scripts/check-base-branch\.sh" "\$\{HEAD_REF\}" "\$\{BASE_REF\}"' "$WORKFLOW"; then
  pass "the guard runs the trusted (base-branch) copy of check-base-branch.sh"
else
  fail "the guard must invoke \${RUNNER_TEMP}/trusted-scripts/check-base-branch.sh — not the PR's own copy"
fi
# The guard is skipped on push (there is no base_ref), so its outcome must only be judged on a PR.
assert_match "the guard step is restricted to pull_request" "if: github.event_name == 'pull_request'" "$wf"

finish
