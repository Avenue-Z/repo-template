#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib.sh
source tests/lib.sh

REPO_RULESET=.github/rulesets/repo-ruleset.json
ORG_RULESET=.github/rulesets/org-ruleset.json

echo "rulesets: valid JSON"
if jq empty "$REPO_RULESET" >/dev/null 2>&1; then pass "$REPO_RULESET is valid JSON"; else fail "$REPO_RULESET is valid JSON"; fi
if jq empty "$ORG_RULESET" >/dev/null 2>&1; then pass "$ORG_RULESET is valid JSON"; else fail "$ORG_RULESET is valid JSON"; fi

echo "rulesets: 'ci' must never be a required context (core has no ci workflow -> pending forever)"
if grep -q '"context": *"ci"' .github/rulesets/*.json; then
  fail "'ci' context found in rulesets (would hang pending forever)"
else
  pass "'ci' context absent from rulesets"
fi

echo "rulesets: required_approving_review_count must be 0 (solo maintainer cannot self-approve)"
for f in "$REPO_RULESET" "$ORG_RULESET"; do
  count=$(jq -r '.rules[] | select(.type=="pull_request") | .parameters.required_approving_review_count' "$f")
  assert_eq "0" "$count" "$f required_approving_review_count is 0"
done

echo "rulesets: required status check contexts match real workflow job keys"
for f in "$REPO_RULESET" "$ORG_RULESET"; do
  contexts=$(jq -r '.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[].context' "$f" | sort)
  expected=$(printf 'guard-base-branch\nsecret-scan')
  assert_eq "$expected" "$contexts" "$f required contexts == {guard-base-branch, secret-scan}"
done

finish
