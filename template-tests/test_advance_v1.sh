#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=template-tests/lib.sh disable=SC1091
source template-tests/lib.sh

WORKFLOW=.github/workflows/advance-v1.yml

# THE ADVANCE IS AN AUTOMATED FLEET-WIDE DEPLOY OF THE SECURITY GATES. Eleven repos execute whatever
# v1 points at, as their only gate. Several mechanics in this workflow are silent when wrong, so they
# are driven here against real git repositories rather than asserted by grep.

echo "advance-v1: the workflow exists and pins the tested commit, not the branch tip"
assert_file "$WORKFLOW exists" "$WORKFLOW"
wf="$(cat "$WORKFLOW")"
assert_match "the checkout fetches full history and tags" 'fetch-depth: 0' "$wf"
assert_match "it chains off template-tests" 'workflows: \[template-tests\]' "$wf"
assert_match "it only acts on a successful upstream run" \
  "workflow_run\.conclusion == 'success'" "$wf"
assert_match "there is an explicit acknowledgement path for an additive change" \
  'acknowledge-contract-change' "$wf"

# A workflow_run-triggered run does NOT default to the commit that triggered the upstream workflow:
# GITHUB_SHA is the last commit on the DEFAULT BRANCH. Two merges in quick succession would therefore
# tag a commit template-tests never ran against.
#
# STRUCTURAL, not grep. A plain `assert_match 'workflow_run\.head_sha' "$wf"` also matches the two
# `env: TARGET_SHA:` lines further down the file — deleting the checkout's entire `with: ref:` line
# still leaves those, so that assertion passed against a file where the exact hazard the workflow's
# own header spends five lines on was unguarded. Read the checkout step's OWN `with.ref` instead.
echo "advance-v1: the checkout step's own ref (not merely the word somewhere in the file) is pinned"
if python3 - "$WORKFLOW" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
ref = d['jobs']['advance']['steps'][0].get('with', {}).get('ref', '')
sys.exit(0 if 'workflow_run.head_sha' in ref else 1)
PY
then
  pass "jobs.advance.steps[0].with.ref pins workflow_run.head_sha"
else
  fail "jobs.advance.steps[0].with.ref must pin workflow_run.head_sha"
fi

# Extract the decision block and drive it for real. Same idiom as test_checks_verdict.sh: the thing
# under test is the SHIPPED script, not a copy of it in this file.
DECIDE="$(mktemp)"; trap 'rm -f "${DECIDE}"' EXIT
python3 - "$WORKFLOW" > "$DECIDE" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for s in d['jobs']['advance']['steps']:
    if s.get('id') == 'decide':
        sys.stdout.write(s['run']); break
else:
    sys.exit("no step with id 'decide' in advance-v1.yml")
PY
if [ -s "$DECIDE" ]; then pass "the 'decide' step's script was extracted"; else fail "advance-v1.yml must contain a step with id 'decide'"; fi

# <msg> <expected-exit> <acknowledged> <contract-changed-since-v1> <v1-exists> [<extra-unrelated-commit>]
#
# Every fixture's first branch is forced to be named "main", regardless of the host's
# init.defaultBranch: the decide block now fetches and merge-bases against origin/main (the ancestry
# guard below), and a fixture left on "master" would fail that guard for a reason that has nothing to
# do with what the scenario is testing.
scenario() {
  local msg="$1" want="$2" ack="$3" changed="$4" have_v1="$5" extra="${6:-no}" rc=0
  local d; d="$(mktemp -d)"
  (
    cd "$d"
    git init -q .; git symbolic-ref HEAD refs/heads/main
    git config user.email t@t; git config user.name t
    # An origin, so the fixture resembles the repo the decide block actually runs in. (Checked:
    # `git fetch --tags --force` exits 0 with no remote configured, so this is not load-bearing
    # today — it is insurance against a decide block that later needs a real fetch to mean anything.)
    git remote add origin "$d"
    mkdir -p .github
    echo '{"job":"checks"}' > .github/reusable-contract.json
    echo base > f; git add -A; git commit -qm base
    [ "$have_v1" = no ] || git tag v1
    if [ "$changed" = yes ]; then echo '{"job":"checks","inputs":["new"]}' > .github/reusable-contract.json; fi
    echo more >> f; git add -A; git commit -qm next
    # A THIRD commit that touches only f, never the contract file. Without this, v1 and HEAD~1 are
    # the SAME commit (whichever one "next" is) and the sticky-comparison-base scenarios below cannot
    # tell "compared against v1" apart from "compared against the previous commit" — see the comment
    # at the call site.
    if [ "$extra" = yes ]; then echo unrelated >> f; git add -A; git commit -qm later; fi
  )
  local target; target="$(git -C "$d" rev-parse HEAD)"
  # $DECIDE is already absolute (mktemp), so it survives the cd.
  ( cd "$d" && ACKNOWLEDGED="$ack" TARGET_SHA="$target" GITHUB_OUTPUT="$d/out" \
      bash "$DECIDE" >/dev/null 2>&1 ) || rc=$?
  assert_eq "$want" "$rc" "$msg"
  rm -rf "$d"
}

echo "advance-v1: the tripwire refuses on a moved contract and keeps refusing"
scenario "contract unchanged since v1 -> advance"                  0 false no  yes
scenario "contract changed since v1 -> REFUSE"                     1 false yes yes
# THE STICKY PROPERTY, for real this time. Comparing against the PREVIOUS COMMIT would make the
# refusal one-shot: the next unrelated push sees an unchanged file, passes, and advances v1 STRAIGHT
# PAST the breaking commit. Comparing against what v1 POINTS AT is what makes the refusal hold until
# a human acts. This needs THREE commits to actually distinguish the two bases: "base" (tagged v1),
# "next" (the contract change), and "later" (touches only f). Target is "later", so:
#   - base v1..later:     the contract changed in "next", which is IN RANGE  -> REFUSE (correct)
#   - base HEAD~1..later: HEAD~1 IS "next" itself, nothing changes AFTER it  -> would wrongly advance
# Proof this is load-bearing: swap the decide block's diff base to HEAD~1 while leaving the
# v1-resolution guard intact, and this scenario alone flips to a false PASS (see task-7-report.md).
scenario "an unrelated push two commits after a refused one -> STILL REFUSE" 1 false yes yes yes
echo "advance-v1: an unresolvable comparison refuses, and an acknowledged change proceeds"
# "I could not tell" is not "nothing changed" — the same posture apply-rulesets.sh:57-62 takes.
scenario "v1 does not resolve -> REFUSE, do not guess"             1 false no  no
# The way out for an ADDITIVE change (a new input WITH a default), which §1 calls backward-compatible
# but which still moves the golden file. Without this the design would call additive changes
# non-breaking and then refuse to ship them.
scenario "an acknowledged additive change -> advance"              0 true  yes yes

# ---------------------------------------------------------------------------------------
# ACKNOWLEDGED IS NOT "TRUST ANY SHA". It skips the contract tripwire, but it must never skip the
# check that the target is actually reachable from main — without that, a dispatch acknowledging a
# real additive change could just as well name an unmerged, never-tested, contract-BREAKING commit
# on a side branch and it would sail through, because ACKNOWLEDGED=true short-circuits before the
# tripwire ever runs. The ancestry guard sits BEFORE that short-circuit specifically to close this.
#
# <msg> <expected-exit> <target-is-on-main>
scenario_ancestry() {
  local msg="$1" want="$2" on_main="$3" rc=0
  local d; d="$(mktemp -d)"
  (
    cd "$d"
    git init -q .; git symbolic-ref HEAD refs/heads/main
    git config user.email t@t; git config user.name t
    git remote add origin "$d"
    mkdir -p .github
    echo '{"job":"checks"}' > .github/reusable-contract.json
    echo base > f; git add -A; git commit -qm base
    git tag v1
    echo more >> f; git add -A; git commit -qm on-main
    if [ "$on_main" = no ]; then
      git checkout -qb side
      echo side-only >> f; git add -A; git commit -qm side-only
    fi
  )
  local target
  if [ "$on_main" = yes ]; then
    target="$(git -C "$d" rev-parse main)"
  else
    target="$(git -C "$d" rev-parse side)"
  fi
  ( cd "$d" && ACKNOWLEDGED=true TARGET_SHA="$target" GITHUB_OUTPUT="$d/out" \
      bash "$DECIDE" >/dev/null 2>&1 ) || rc=$?
  assert_eq "$want" "$rc" "$msg"
  rm -rf "$d"
}

echo "advance-v1: an acknowledged dispatch still must name a commit that is actually on main"
scenario_ancestry "acknowledged dispatch, SHA is on main -> advance"                0 yes
scenario_ancestry "acknowledged dispatch, SHA is NOT an ancestor of main -> REFUSE" 1 no

finish
