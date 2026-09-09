#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=template-tests/lib.sh disable=SC1091
source template-tests/lib.sh

WORKFLOW=.github/workflows/advance-v1.yml

# THE ADVANCE IS AN AUTOMATED FLEET-WIDE DEPLOY OF THE SECURITY GATES. Eleven repos execute whatever
# v1 points at, as their only gate. Two mechanics in this workflow are silent when wrong, so they are
# driven here against real git repositories rather than asserted by grep.

echo "advance-v1: the workflow exists and pins the tested commit, not the branch tip"
assert_file "$WORKFLOW exists" "$WORKFLOW"
wf="$(cat "$WORKFLOW")"
# A workflow_run-triggered run does NOT default to the commit that triggered the upstream workflow:
# GITHUB_SHA is the last commit on the DEFAULT BRANCH. Two merges in quick succession would therefore
# tag a commit template-tests never ran against.
assert_match "the checkout pins workflow_run.head_sha" \
  'github\.event\.workflow_run\.head_sha' "$wf"
assert_match "the checkout fetches full history and tags" 'fetch-depth: 0' "$wf"
assert_match "it chains off template-tests" 'workflows: \[template-tests\]' "$wf"
assert_match "it only acts on a successful upstream run" \
  "workflow_run\.conclusion == 'success'" "$wf"
assert_match "there is an explicit acknowledgement path for an additive change" \
  'acknowledge-contract-change' "$wf"

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

# <msg> <expected-exit> <acknowledged> <contract-changed-since-v1> <v1-exists>
scenario() {
  local msg="$1" want="$2" ack="$3" changed="$4" have_v1="$5" rc=0
  local d; d="$(mktemp -d)"
  (
    cd "$d"
    git init -q .; git config user.email t@t; git config user.name t
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
# THE STICKY PROPERTY. Comparing against the PREVIOUS COMMIT would make the refusal one-shot: the next
# unrelated push sees an unchanged file, passes, and advances v1 straight past the breaking commit.
# Comparing against what v1 POINTS AT is what makes the refusal hold until a human acts. The scenario
# above already encodes it — `next` does not touch the contract file, yet the diff base is still v1.
scenario "an unrelated push after a refused one -> STILL REFUSE"   1 false yes yes
echo "advance-v1: an unresolvable comparison refuses, and an acknowledged change proceeds"
# "I could not tell" is not "nothing changed" — the same posture apply-rulesets.sh:57-62 takes.
scenario "v1 does not resolve -> REFUSE, do not guess"             1 false no  no
# The way out for an ADDITIVE change (a new input WITH a default), which §1 calls backward-compatible
# but which still moves the golden file. Without this the design would call additive changes
# non-breaking and then refuse to ship them.
scenario "an acknowledged additive change -> advance"              0 true  yes yes

finish
