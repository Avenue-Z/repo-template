#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib.sh
source tests/lib.sh

echo "apply-rulesets: honest reporting"
if out=$(./scripts/apply-rulesets.sh --dry-run 2>&1); then
  pass "--dry-run exits 0"
else
  fail "--dry-run should exit 0 even when protection is impossible"
fi
echo "$out" | grep -qiE 'free|skip|cannot|unavailable|would apply' \
  && pass "explains what it did or skipped" \
  || fail "silent — must say what it skipped and why"

echo "apply-rulesets: anti-brick — no ci.yml in template core means 'ci' must never be required"
if [ -f .github/workflows/ci.yml ]; then
  fail "template core unexpectedly has ci.yml — this test's premise no longer holds, update it"
else
  pass "confirmed no ci.yml present (test precondition for the anti-brick case)"
fi
echo "$out" | grep -qE 'required: ci$' \
  && fail "'ci' listed as a required status check with no ci.yml present (would hang PRs forever)" \
  || pass "'ci' is NOT listed as a required status check"
echo "$out" | grep -q 'required: guard-base-branch' \
  && pass "'guard-base-branch' is listed as required" \
  || fail "'guard-base-branch' should be listed as required"
echo "$out" | grep -q 'required: secret-scan' \
  && pass "'secret-scan' is listed as required" \
  || fail "'secret-scan' should be listed as required"

echo "apply-rulesets: --org honest reporting (org-level rulesets need GitHub Team)"
if out_org=$(./scripts/apply-rulesets.sh --org --dry-run 2>&1); then
  pass "--org --dry-run exits 0"
else
  fail "--org --dry-run should exit 0 even when Team is required"
fi
echo "$out_org" | grep -qiE 'team|free' \
  && pass "--org explains the Team/Free limitation" \
  || fail "--org run is silent about the Team requirement"

finish
