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

# The three prefixes added when the matrix became org-wide (spec §1). perf/ has 2 real uses in the
# fleet; refactor/ and test/ are conventional-commit types added pre-emptively, on the reasoning that
# a contributor who reaches for a legitimate type and is refused learns the guard is arbitrary rather
# than that their branch is wrong.
assert_pass perf/x dev
assert_pass refactor/x dev
assert_pass test/x dev

assert_fail feat/x main
assert_fail feat/x staging
assert_fail dev main
assert_fail staging dev
assert_fail wip/x dev
assert_fail randomname dev

# The three deliberate exclusions (spec §1 and Rejected). Each was wanted at some point.
assert_fail security/x dev     # a dep bump is fix(deps): -> fix/. The guard was right.
assert_fail feature/x dev      # the most common near-miss; must be REJECTED, not accepted
assert_fail revert/x dev       # GitHub's Revert button generates revert-<PR#>-<branch>, with a HYPHEN
assert_fail revert-42-feat/x dev

echo "guard-base-branch: the error message names the correction for the common near-miss"
# The single most common near-miss is feature/ (6 branches in the fleet). Rejecting it silently and
# rejecting it with "use feat/, not feature/" cost the same to implement and differ entirely in
# whether the contributor's next push succeeds.
msg="$("$SCRIPT" feature/x dev 2>&1 || true)"
assert_match "the guard names feat/ when it rejects feature/" 'use feat/, not feature/' "$msg"
# Once the script is central, scripts/check-base-branch.sh does not exist in the contributor's repo.
# Telling them to edit a path they cannot see, in the moment they are already confused, is worse than
# saying nothing. The message must point at a PR against the template instead.
assert_nomatch "the guard no longer tells a consumer to edit a file they do not have" \
  'case statement in scripts/check-base-branch\.sh' "$msg"
assert_match "the guard points at a PR against the template" 'Avenue-Z/repo-template' "$msg"
assert_match "the guard's own output lists the full matrix" \
  'perf/.*refactor/.*test/' "$msg"

echo "guard-base-branch: the guard's logic must not be supplied by the PR it judges"
# The workflow runs on pull_request, so a default checkout gives it the PR HEAD's tree — which means
# the PR supplies the very script that judges it. A PR from wip/x -> main that also rewrote
# check-base-branch.sh to `exit 0` would pass its own guard, and with
# required_approving_review_count: 0 nobody has to look at it.
#
# The base-branch checkout that used to close this is GONE: on the consumer path there is no base
# branch worth trusting, and the scripts now come from the TEMPLATE at the ref this workflow was
# called at. See the spec, §2.
wf="$(cat "$WORKFLOW")"
# job_workflow_ref, NOT workflow_ref. The latter is the CALLER's workflow and resolving the scripts
# from it would stage a consumer's own tree. The former is this called workflow's ref path, e.g.
# Avenue-Z/repo-template/.github/workflows/checks.yml@refs/tags/v1.2.0 — which is also what makes the
# immutable point tags an actual rollback rather than a rollback of the YAML only.
assert_match "the script ref comes from github.job_workflow_ref" 'github\.job_workflow_ref' "$wf"
assert_nomatch "the script ref is NOT taken from github.workflow_ref (that is the caller's)" \
  'github\.workflow_ref' "$wf"
# A hardcoded tag would defeat the point tags exactly as silently: checks.yml@v1.2.0 would execute
# scripts staged from the moving v1.
assert_nomatch "the template checkout does not hardcode a tag" 'ref: *v1 *$' "$wf"
# repo-template's own PRs take the workspace copy instead, so a PR that CHANGES a gate script is
# exercised by the run reviewing it, and so that Phase A's first PR is not red on a tag Phase A
# exists to cut.
assert_match "the staging step branches on the caller's repository" 'Avenue-Z/repo-template' "$wf"
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
