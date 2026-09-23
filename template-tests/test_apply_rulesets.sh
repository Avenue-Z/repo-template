#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=template-tests/lib.sh disable=SC1091
source template-tests/lib.sh

# This block drives the REAL gh against the REAL org: apply-rulesets.sh reads the org plan before
# it does anything, and every decision below hangs off it. A CI runner's GITHUB_TOKEN is
# repo-scoped and cannot read org details, so skip there rather than fail a run for a reason that
# has nothing to do with the change under test. The stub-driven cases further down cover the same
# decision logic without the network; this one exists to prove it works against the real API.
echo "apply-rulesets: honest reporting (needs live org access)"
if ! have_org_access; then
  skip "no authenticated access to the Avenue-Z org (expected on a CI runner) — the live-gh checks below are NOT running"
  skip "  the stub-driven cases further down still cover the same decision logic"
else
  if out=$(./scripts/apply-rulesets.sh --dry-run 2>&1); then
    pass "--dry-run exits 0"
  else
    fail "--dry-run should exit 0 even when protection is impossible"
  fi
  assert_match "explains what it did or skipped" 'free|skip|cannot|unavailable|would apply' "$out"

  echo "apply-rulesets: anti-brick — no ci.yml in template core means 'ci' must never be required"
  if [ -f .github/workflows/ci.yml ]; then
    fail "template core unexpectedly has ci.yml — this test's premise no longer holds, update it"
  else
    pass "confirmed no ci.yml present (test precondition for the anti-brick case)"
  fi
  assert_nomatch "'ci' is NOT listed as a required status check" 'required: ci$' "$out"
  # THIS repo's checks.yml declares workflow_call, so it is the template and reports plain `checks`.
  assert_match   "'checks' is required here (this checks.yml declares workflow_call)" 'required: checks$' "$out"
  assert_nomatch "'checks / checks' is NOT required here" 'required: checks / checks' "$out"
  # The three contexts the merged `checks` job replaced must NOT still be demanded. Leaving one
  # behind is the brick: nothing reports it any more, so it hangs every PR PENDING FOREVER.
  assert_nomatch "'guard-base-branch' is no longer required (it is a step of 'checks')" 'required: guard-base-branch' "$out"
  assert_nomatch "'secret-scan' is no longer required (it is a step of 'checks')" 'required: secret-scan' "$out"
  assert_nomatch "'sca' is no longer required (it is a step of 'checks')" 'required: sca$' "$out"
  # The MIRROR of the anti-brick case: the template DOES carry template-tests.yml, so the file-gated
  # add_context MUST inject 'template-tests' here. Asserting the injection (not just its absence when
  # the workflow is gone) is the behavioral coverage the file-gating condition otherwise lacked — a
  # regression that required it unconditionally would hang every PR in a generated repo pending forever.
  assert_match   "'template-tests' IS listed as required (its workflow is present in the template)" 'required: template-tests' "$out"
fi

# ---------------------------------------------------------------------------------------
# --org IS GONE FROM THIS SCRIPT, AND MUST STAY GONE.
#
# The org-wide apply used to live here behind `--org` — one flag away from the command you run on
# every new repo. That adjacency WAS the vulnerability: a fat-finger, a stray tab-complete, or an
# Up-arrow through shell history was all that separated "protect my repo" from "rewrite protection
# on all ~64 repos in Avenue-Z". It now lives in scripts/apply-org-ruleset.sh.
#
# These assertions exist so nobody re-adds the flag here for convenience. Convenience is exactly
# what we removed.
echo "apply-rulesets: --org must NOT be reachable from this script"
if out_org=$(./scripts/apply-rulesets.sh --org --dry-run 2>&1); then
  fail "--org still works on apply-rulesets.sh — the org-wide apply must not be one flag away from the routine command"
else
  pass "--org is refused by apply-rulesets.sh"
fi
assert_match "points the operator at the separate org script" 'apply-org-ruleset\.sh' "$out_org"
assert_nomatch "does not apply anything" 'created new org ruleset|updated existing org ruleset' "$out_org"

echo "apply-rulesets: --yes must NOT exist here either"
if out_yes=$(./scripts/apply-rulesets.sh --yes --dry-run 2>&1); then
  fail "--yes is still accepted — it is a consent bypass and must not exist"
else
  pass "--yes is refused by apply-rulesets.sh"
fi
assert_match   "explains there is no --yes to reach for" 'no --yes on this script' "$out_yes"
assert_nomatch "does not apply anything" 'created new ruleset|updated existing ruleset' "$out_yes"

# The script must not even CONTAIN the org-apply code any more. A flag guard that sits in front of
# a still-present POST to orgs/<org>/rulesets is one edit away from being reachable again.
echo "apply-rulesets: the org-apply code must be ABSENT, not merely guarded"
src="$(cat scripts/apply-rulesets.sh)"
assert_nomatch "no POST to orgs/<org>/rulesets anywhere in this script" 'orgs/\$\{ORG\}/rulesets' "$src"
assert_nomatch "no ~ALL / org-repo enumeration left behind" 'orgs/\$\{ORG\}/repos' "$src"

# ---------------------------------------------------------------------------------------
# CRITERION 6 — the private + Free path must be HONEST.
#
# Every run above exits early at "cannot determine target repo" (this working copy has no
# GitHub remote), so NOTHING above ever reaches the private+Free branch. That branch is the
# whole point of the script: on Free, branch protection does not exist for private repos,
# and the script must say so — "main is NOT protected, a direct push WILL succeed" — instead
# of claiming success. To actually drive it, put a fake `gh` on PATH that answers `free` for
# the plan and `PRIVATE` for the visibility. Without this, replacing the entire warning block
# with `info "protection applied."` — a script that LIES — still passed the suite.
echo "apply-rulesets: criterion 6 — private repo + Free plan reports the truth"
STUB="$(mktemp -d)"
trap 'rm -rf "${STUB}"' EXIT
cat > "${STUB}/gh" <<'STUBEOF'
#!/usr/bin/env bash
# Minimal fake gh: a private repo in an org on the Free plan.
case "$*" in
  *"orgs/Avenue-Z"*)  echo free ;;
  *nameWithOwner*)    echo "Avenue-Z/fake-private-repo" ;;
  *visibility*)       echo "PRIVATE" ;;
  *) echo "fake gh: unexpected call: gh $*" >&2; exit 1 ;;
esac
STUBEOF
chmod +x "${STUB}/gh"

if out_priv=$(PATH="${STUB}:${PATH}" ./scripts/apply-rulesets.sh --dry-run 2>&1); then
  pass "private+Free exits 0 (a plan limit is an honest report, not an error)"
else
  fail "private+Free should exit 0, got non-zero. Output: ${out_priv}"
fi
assert_match   "says main/staging/dev are NOT protected" 'not protected' "$out_priv"
assert_match   "says a direct push to main will succeed" 'direct push to main will succeed' "$out_priv"
assert_nomatch "makes no false claim of applied protection" 'ruleset applied|protection applied|now protected' "$out_priv"

# ---------------------------------------------------------------------------------------
# IDEMPOTENCY — GitHub allows multiple rulesets with the same name. A plain unconditional
# POST every run would create a duplicate instead of updating the one already in force.
# These cases drive a repo that IS reachable (PUBLIC, so the Free-plan honesty exit above
# is never hit) and vary what the rulesets-list GET returns.
echo "apply-rulesets: idempotency — existing ruleset with matching name triggers update (PUT), not a duplicate create"
cat > "${STUB}/gh" <<'STUBEOF'
#!/usr/bin/env bash
case "$*" in
  *"orgs/Avenue-Z"*)                          echo team ;;
  *nameWithOwner*)                            echo "Avenue-Z/repo-template" ;;
  *visibility*)                               echo "PUBLIC" ;;
  *"repos/Avenue-Z/repo-template/rulesets"*)  echo '[{"id":18889104,"name":"avenue-z-branch-protection"}]' ;;
  *) echo "fake gh: unexpected call: gh $*" >&2; exit 1 ;;
esac
STUBEOF
chmod +x "${STUB}/gh"

if out_update=$(PATH="${STUB}:${PATH}" ./scripts/apply-rulesets.sh --dry-run 2>&1); then
  pass "existing-ruleset dry-run exits 0"
else
  fail "existing-ruleset dry-run should exit 0. Output: ${out_update}"
fi
assert_match   "says it would PUT/update the existing ruleset" 'put|update' "$out_update"
assert_match   "names the existing ruleset id 18889104" '18889104' "$out_update"
assert_nomatch "does not say it would POST/create a new ruleset" 'would post|create new' "$out_update"

echo "apply-rulesets: idempotency — no existing ruleset with matching name triggers create (POST)"
cat > "${STUB}/gh" <<'STUBEOF'
#!/usr/bin/env bash
case "$*" in
  *"orgs/Avenue-Z"*)                          echo team ;;
  *nameWithOwner*)                            echo "Avenue-Z/repo-template" ;;
  *visibility*)                               echo "PUBLIC" ;;
  *"repos/Avenue-Z/repo-template/rulesets"*)  echo '[]' ;;
  *) echo "fake gh: unexpected call: gh $*" >&2; exit 1 ;;
esac
STUBEOF
chmod +x "${STUB}/gh"

if out_create=$(PATH="${STUB}:${PATH}" ./scripts/apply-rulesets.sh --dry-run 2>&1); then
  pass "no-existing-ruleset dry-run exits 0"
else
  fail "no-existing-ruleset dry-run should exit 0. Output: ${out_create}"
fi
assert_match   "says it would POST/create a new ruleset" 'would post|create new' "$out_create"
assert_nomatch "does not say it would PUT/update an existing ruleset" 'would put|update existing' "$out_create"

echo "apply-rulesets: idempotency — a failed ruleset-list lookup must die, not silently create a duplicate"
cat > "${STUB}/gh" <<'STUBEOF'
#!/usr/bin/env bash
case "$*" in
  *"orgs/Avenue-Z"*)                          echo team ;;
  *nameWithOwner*)                            echo "Avenue-Z/repo-template" ;;
  *visibility*)                               echo "PUBLIC" ;;
  *"repos/Avenue-Z/repo-template/rulesets"*)  echo "HTTP 403: Forbidden (rate limited)" >&2; exit 1 ;;
  *) echo "fake gh: unexpected call: gh $*" >&2; exit 1 ;;
esac
STUBEOF
chmod +x "${STUB}/gh"

if out_fail=$(PATH="${STUB}:${PATH}" ./scripts/apply-rulesets.sh --dry-run 2>&1); then
  fail "a failed ruleset lookup should NOT exit 0 — it must die rather than guess. Output: ${out_fail}"
else
  pass "a failed ruleset lookup makes the script die (non-zero exit)"
fi
assert_match   "explains the lookup failure" 'cannot list existing rulesets' "$out_fail"
assert_nomatch "never falls through to claiming it would create/POST a duplicate" 'would post|create new' "$out_fail"

# ---------------------------------------------------------------------------------------
# THE OTHER BRANCH — a CALLER's checks.yml must require the renamed 'checks / checks' context.
#
# The guarded block at the top of this file proves the template's own case (plain `checks`), but
# it only runs with real Avenue-Z org access — never on a CI runner, whose GITHUB_TOKEN is
# repo-scoped. Asserting only that branch is how the CONSUMER branch would ship untested, and the
# consumer branch is the one that runs in the ~11 generated repos. So this block runs
# UNCONDITIONALLY, driving a caller-shaped checks.yml through the same gh-stub technique used
# above.
#
# The fixture is a temp directory holding COPIES of THIS WORKING TREE's apply-rulesets.sh and
# repo-ruleset.json — not a `git clone`, which would exercise the last COMMITTED version rather
# than the change under test — plus a caller-shaped checks.yml. It deliberately carries no
# ci.yml or template-tests.yml, so those two contexts stay correctly absent and the negative
# assertions elsewhere in this suite stay meaningful.
echo "apply-rulesets: a CALLER's checks.yml requires the renamed 'checks / checks' context"
FIXTURE="$(mktemp -d)"
mkdir -p "${FIXTURE}/scripts" "${FIXTURE}/.github/rulesets" "${FIXTURE}/.github/workflows"
cp scripts/apply-rulesets.sh "${FIXTURE}/scripts/apply-rulesets.sh"
cp .github/rulesets/repo-ruleset.json "${FIXTURE}/.github/rulesets/repo-ruleset.json"
cat > "${FIXTURE}/.github/workflows/checks.yml" <<'CALLER'
name: checks
on:
  pull_request:
    types: [opened, edited, reopened, synchronize]
jobs:
  checks:
    permissions:
      contents: read
      id-token: write
    uses: Avenue-Z/repo-template/.github/workflows/checks.yml@v1
CALLER

cat > "${STUB}/gh" <<'STUBEOF'
#!/usr/bin/env bash
# Minimal fake gh: only needs to answer the org-plan lookup so the script gets past it and
# prints the required-checks list, which happens before any repo lookup.
case "$*" in
  *"orgs/Avenue-Z"*) echo free ;;
  *) echo "fake gh: unexpected call: gh $*" >&2; exit 1 ;;
esac
STUBEOF
chmod +x "${STUB}/gh"

cout="$(cd "${FIXTURE}" && PATH="${STUB}:${PATH}" ./scripts/apply-rulesets.sh --dry-run 2>&1)" || true
assert_match   "a caller requires 'checks / checks'" 'required: checks / checks' "$cout"
assert_nomatch "a caller does NOT require the plain 'checks' context" 'required: checks$' "$cout"
rm -rf "${FIXTURE}"

# ---------------------------------------------------------------------------------------
# THE THIRD SHAPE — a SELF-CONTAINED copy of checks.yml (no `workflow_call:`, and no `uses:` on
# the `checks` job either) is the documented migration ROLLBACK path, and every one of the ~11
# fleet repos holds exactly this shape today. Keying the decision on the ABSENCE of
# `workflow_call` (instead of the PRESENCE of a `uses:`) used to fold this into the caller branch
# and require `checks / checks` on a checks.yml that actually reports plain `checks` — on a repo
# with live rulesets that hangs every PR PENDING FOREVER. Same fixture technique as the caller
# case above: copies of this working tree's apply-rulesets.sh and repo-ruleset.json, not a
# `git clone`.
echo "apply-rulesets: a SELF-CONTAINED copy of checks.yml (the migration rollback path) requires plain 'checks'"
FIXTURE3="$(mktemp -d)"
mkdir -p "${FIXTURE3}/scripts" "${FIXTURE3}/.github/rulesets" "${FIXTURE3}/.github/workflows"
cp scripts/apply-rulesets.sh "${FIXTURE3}/scripts/apply-rulesets.sh"
cp .github/rulesets/repo-ruleset.json "${FIXTURE3}/.github/rulesets/repo-ruleset.json"
cat > "${FIXTURE3}/.github/workflows/checks.yml" <<'SELFCONTAINED'
name: checks
on:
  pull_request:
    types: [opened, edited, reopened, synchronize]
jobs:
  checks:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - name: run the gates
        run: echo "self-contained rollback copy — no workflow_call, no uses: on the checks job"
SELFCONTAINED

cat > "${STUB}/gh" <<'STUBEOF'
#!/usr/bin/env bash
# Minimal fake gh: only needs to answer the org-plan lookup, same as the caller case above.
case "$*" in
  *"orgs/Avenue-Z"*) echo free ;;
  *) echo "fake gh: unexpected call: gh $*" >&2; exit 1 ;;
esac
STUBEOF
chmod +x "${STUB}/gh"

cout3="$(cd "${FIXTURE3}" && PATH="${STUB}:${PATH}" ./scripts/apply-rulesets.sh --dry-run 2>&1)" || true
assert_match   "a self-contained copy requires plain 'checks'" 'required: checks$' "$cout3"
assert_nomatch "a self-contained copy does NOT require 'checks / checks'" 'required: checks / checks' "$cout3"
rm -rf "${FIXTURE3}"

# ---------------------------------------------------------------------------------------
# A CALLER WITHOUT `id-token: write` MUST BE REFUSED, not given a required context.
#
# checks.yml requests id-token: write. A caller whose `checks` job does not grant it is asking for
# an ELEVATION, and that does not fail the job: the run is a `startup_failure` with ZERO jobs, so
# `checks / checks` never reports (measured: avenue-z-ci-lab/adopter-private run 34709355618).
# Requiring that context then hangs every PR PENDING FOREVER. init-repo.sh writes the grant for new
# repos; this is the guard for the repos migrated to a caller by hand.
#
# What counts is the `checks` job's EFFECTIVE grant: its own `permissions` block REPLACES the
# workflow-level one, and only if it has none does the workflow-level block apply. Each fixture
# below is shaped so one specific wrong reading of that rule would pass it. Same fixture technique
# as above; the gh stub is the org-plan-only one the self-contained case left in place, so an
# accepted run gets past the required-checks list and stops at "cannot determine target repo".
caller_run() { # <checks.yml content> -- sets CALLER_RC and CALLER_OUT
  local fx
  fx="$(mktemp -d)"
  mkdir -p "${fx}/scripts" "${fx}/.github/rulesets" "${fx}/.github/workflows"
  cp scripts/apply-rulesets.sh "${fx}/scripts/apply-rulesets.sh"
  cp .github/rulesets/repo-ruleset.json "${fx}/.github/rulesets/repo-ruleset.json"
  printf '%s\n' "$1" > "${fx}/.github/workflows/checks.yml"
  CALLER_RC=0
  CALLER_OUT="$(cd "${fx}" && PATH="${STUB}:${PATH}" ./scripts/apply-rulesets.sh --dry-run 2>&1)" || CALLER_RC=$?
  rm -rf "${fx}"
}
assert_refused() { # <what>
  if [ "${CALLER_RC}" -ne 0 ]; then pass "$1: refused (non-zero exit, even under --dry-run)"; else fail "$1: should be refused, exited 0. Output: ${CALLER_OUT}"; fi
  assert_match   "$1: the refusal names the missing grant" 'id-token: write' "${CALLER_OUT}"
  assert_nomatch "$1: never gets as far as requiring 'checks / checks'" 'required: checks / checks' "${CALLER_OUT}"
}

echo "apply-rulesets: a caller that grants nothing is refused"
caller_run 'name: checks
on: pull_request
jobs:
  checks:
    uses: Avenue-Z/repo-template/.github/workflows/checks.yml@v1'
assert_refused "no permissions anywhere"

# Breaks if the grant is found by searching TEXT: it appears here only in comments and on a
# different job, never on `checks`.
echo "apply-rulesets: a grant that exists only in comments or on another job is refused"
caller_run 'name: checks
on: pull_request
# the checks job needs id-token: write
jobs:
  checks:
    # id-token: write
    permissions:
      contents: read
      # id-token: write
    uses: Avenue-Z/repo-template/.github/workflows/checks.yml@v1
  other:
    permissions:
      id-token: write
    runs-on: ubuntu-latest
    steps:
      - run: true'
assert_refused "grant only in comments / on another job"

# Breaks if the workflow-level block is consulted even though the job has its own.
echo "apply-rulesets: a workflow-level grant REPLACED by a job-level block without it is refused"
caller_run 'name: checks
on: pull_request
permissions:
  contents: read
  id-token: write
jobs:
  checks:
    permissions:
      contents: read
    uses: Avenue-Z/repo-template/.github/workflows/checks.yml@v1'
assert_refused "job-level block drops the workflow-level grant"

# Breaks if only the job-level block is read: with no job block, the workflow-level grant applies.
# The column-0 comment inside the block is valid YAML; it breaks a reader that lets a comment end a
# block, and the trailing comment breaks one that anchors the grant at end of line.
echo "apply-rulesets: a workflow-level grant with no job-level block is accepted"
caller_run 'name: checks
on: pull_request
permissions:
  contents: read
# the grant below is for checks.yml
  id-token: write  # checks.yml mints an OIDC token to learn its own ref
jobs:
  checks:
    uses: Avenue-Z/repo-template/.github/workflows/checks.yml@v1'
if [ "${CALLER_RC}" -eq 0 ]; then pass "workflow-level grant: accepted (exit 0)"; else fail "workflow-level grant: should be accepted, exited ${CALLER_RC}. Output: ${CALLER_OUT}"; fi
assert_match "workflow-level grant: requires 'checks / checks'" 'required: checks / checks' "${CALLER_OUT}"

# ---------------------------------------------------------------------------------------
# THE SAME REFUSAL FOR ci.yml. python-ci.yml requests id-token: write, so a ci.yml whose python-ci
# caller job does not grant it is a startup_failure: `ci` never reports, and requiring it hangs every
# PR PENDING FOREVER (lab-observed in Phase G, Task 6 Step 5). init-repo.sh ships the grant; this is
# the guard for callers written by hand during migration.
GRANTED_CHECKS='name: checks
on: pull_request
jobs:
  checks:
    permissions:
      contents: read
      id-token: write
    uses: Avenue-Z/repo-template/.github/workflows/checks.yml@v1'
ci_caller_run() { # <ci.yml content> -- sets CALLER_RC and CALLER_OUT
  local fx
  fx="$(mktemp -d)"
  mkdir -p "${fx}/scripts" "${fx}/.github/rulesets" "${fx}/.github/workflows"
  cp scripts/apply-rulesets.sh "${fx}/scripts/apply-rulesets.sh"
  cp .github/rulesets/repo-ruleset.json "${fx}/.github/rulesets/repo-ruleset.json"
  printf '%s\n' "${GRANTED_CHECKS}" > "${fx}/.github/workflows/checks.yml"
  printf '%s\n' "$1" > "${fx}/.github/workflows/ci.yml"
  CALLER_RC=0
  CALLER_OUT="$(cd "${fx}" && PATH="${STUB}:${PATH}" ./scripts/apply-rulesets.sh --dry-run 2>&1)" || CALLER_RC=$?
  rm -rf "${fx}"
}

echo "apply-rulesets: a python-ci caller that grants nothing is refused"
ci_caller_run 'name: ci
on: pull_request
jobs:
  python-ci:
    uses: Avenue-Z/repo-template/.github/workflows/python-ci.yml@python-ci-v1
  ci:
    needs: [python-ci]
    runs-on: ubuntu-latest'
if [ "${CALLER_RC}" -ne 0 ]; then pass "refused (non-zero exit)"; else fail "should be refused, exited 0. Output: ${CALLER_OUT}"; fi
assert_match   "the refusal names the missing grant" 'id-token: write' "${CALLER_OUT}"
assert_nomatch "it never gets as far as requiring 'ci'" 'required: ci$' "${CALLER_OUT}"

echo "apply-rulesets: a python-ci caller that grants it requires 'ci'"
ci_caller_run 'name: ci
on: pull_request
jobs:
  python-ci:
    permissions:
      contents: read
      id-token: write
    uses: Avenue-Z/repo-template/.github/workflows/python-ci.yml@python-ci-v1
  ci:
    needs: [python-ci]
    runs-on: ubuntu-latest'
assert_match "a granted python-ci caller requires 'ci'" 'required: ci$' "${CALLER_OUT}"

# The caller init-repo.sh actually ships, not a fixture shaped like it: comments between the header and
# its permissions, and a `with:` block. A false REFUSAL here fails apply-rulesets on every new Python repo.
echo "apply-rulesets: the Python template's own ci.yml is accepted and requires 'ci'"
ci_caller_run "$(cat templates/python/.github/workflows/ci.yml)"
if [ "${CALLER_RC}" -eq 0 ]; then pass "shipped caller: accepted (exit 0)"; else fail "shipped caller: should be accepted, exited ${CALLER_RC}. Output: ${CALLER_OUT}"; fi
assert_match "shipped caller: requires 'ci'" 'required: ci$' "${CALLER_OUT}"

echo "apply-rulesets: a self-contained ci.yml (no python-ci caller) is unaffected"
ci_caller_run 'name: ci
on: pull_request
jobs:
  test:
    runs-on: ubuntu-latest
  ci:
    needs: [test]
    runs-on: ubuntu-latest'
assert_match "a ci.yml with no python-ci caller still requires 'ci'" 'required: ci$' "${CALLER_OUT}"

# Breaks if the caller job is found by "the last 2-space key before the uses: line". The header's
# trailing comment is valid YAML, but a reader matching only a bare `  name:` skips it and credits the
# call to `other` — which DOES hold the grant, so the wrong job passes and `ci` is required on a caller
# that will startup_failure. A header this script cannot read must be refused, never guessed.
echo "apply-rulesets: a python-ci caller whose job header it cannot read is refused, not credited to another job"
ci_caller_run 'name: ci
on: pull_request
jobs:
  other:
    permissions:
      contents: read
      id-token: write
    runs-on: ubuntu-latest
  python-ci:  # the reusable Python CI
    uses: Avenue-Z/repo-template/.github/workflows/python-ci.yml@python-ci-v1
  ci:
    needs: [python-ci]
    runs-on: ubuntu-latest'
if [ "${CALLER_RC}" -ne 0 ]; then pass "unreadable header: refused (non-zero exit)"; else fail "unreadable header: should be refused, exited 0. Output: ${CALLER_OUT}"; fi
assert_nomatch "unreadable header: never gets as far as requiring 'ci'" 'required: ci$' "${CALLER_OUT}"

# Breaks if only the FIRST caller is checked: the second one here has no grant.
echo "apply-rulesets: every python-ci caller job is checked, not just the first"
ci_caller_run 'name: ci
on: pull_request
jobs:
  python-ci:
    permissions:
      contents: read
      id-token: write
    uses: Avenue-Z/repo-template/.github/workflows/python-ci.yml@python-ci-v1
  python-ci-lib:
    uses: Avenue-Z/repo-template/.github/workflows/python-ci.yml@python-ci-v1
  ci:
    needs: [python-ci, python-ci-lib]
    runs-on: ubuntu-latest'
if [ "${CALLER_RC}" -ne 0 ]; then pass "second caller ungranted: refused (non-zero exit)"; else fail "second caller ungranted: should be refused, exited 0. Output: ${CALLER_OUT}"; fi
assert_match   "second caller ungranted: the refusal names that job" "'python-ci-lib'" "${CALLER_OUT}"
assert_nomatch "second caller ungranted: never gets as far as requiring 'ci'" 'required: ci$' "${CALLER_OUT}"

finish
