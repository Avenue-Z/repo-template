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

cout="$(cd "${FIXTURE}" && PATH="${STUB}:${PATH}" ./scripts/apply-rulesets.sh --dry-run 2>&1 || true)"
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

cout3="$(cd "${FIXTURE3}" && PATH="${STUB}:${PATH}" ./scripts/apply-rulesets.sh --dry-run 2>&1 || true)"
assert_match   "a self-contained copy requires plain 'checks'" 'required: checks$' "$cout3"
assert_nomatch "a self-contained copy does NOT require 'checks / checks'" 'required: checks / checks' "$cout3"
rm -rf "${FIXTURE3}"

finish
