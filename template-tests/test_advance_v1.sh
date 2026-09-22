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
# THE EXACT `if:`, read from the parsed YAML. `branches: [main]` filters on the upstream run's HEAD
# BRANCH NAME, so a pull_request run of template-tests whose head branch is `main` (a back-merge PR
# out of main, or a fork's main) matches it. That run skips both push-only self-calls, so it can be green while proving nothing
# about the reusable workflows — and it would move BOTH tags. `event == 'push'` is what refuses it.
want_if="github.event_name == 'workflow_dispatch' || (github.event.workflow_run.conclusion == 'success' && github.event.workflow_run.event == 'push')"
got_if="$(python3 -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))["jobs"]["advance"]["if"])' "$WORKFLOW" 2>&1)" || true
assert_eq "$want_if" "$got_if" "it only acts on a dispatch, or a SUCCESSFUL upstream run triggered by a PUSH"
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
# THE TAG PROTECTION AND THE TOKEN ARE ONE MECHANISM, so they are asserted together.
#
# `v1` carries a ruleset (deletion + non_fast_forward) and a ruleset applies to GITHUB_TOKEN like any
# other actor, so the advance needs a bypass. The design's first attempt -- the GitHub Actions app
# (id 15368) as an `Integration` bypass actor -- IS NOT AVAILABLE: the API rejects it with "Actor
# GitHub Actions integration must be part of the ruleset source or owner organization", because
# GitHub Actions is not an installable app and never appears in an org's installations. So the push
# authenticates as a DEDICATED APP, which is the ruleset's one bypass actor.
#
# The half that is easy to lose later: GITHUB_TOKEN must NOT carry `contents: write` here. The app
# token is what moves the tag; leaving write on GITHUB_TOKEN adds a second credential that looks like
# it should work, and the next person debugging a failed advance will "fix" it by dropping the app
# token and widening the bypass instead.
#
# Located by `uses:`, NOT by index. The previous form read steps[0] and broke the moment a step was
# inserted ahead of the checkout -- which is exactly what the app token requires.
echo "advance-v1: the checkout pins the tested commit and authenticates as the bypass app"
if ! err="$(python3 - "$WORKFLOW" 2>&1 <<'PYCHK'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
job = d['jobs']['advance']
steps = job['steps']

tok = next((s for s in steps if s.get('id') == 'app-token'), None)
if tok is None:
    sys.exit("no step with id 'app-token' -- the tag push has no bypass credential")
if not str(tok.get('uses', '')).startswith('actions/create-github-app-token@'):
    sys.exit("the 'app-token' step must use actions/create-github-app-token")

co = next((s for s in steps if str(s.get('uses', '')).startswith('actions/checkout@')), None)
if co is None:
    sys.exit("no actions/checkout step in the advance job")
w = co.get('with', {})
if 'workflow_run.head_sha' not in str(w.get('ref', '')):
    sys.exit("the checkout's own with.ref must pin workflow_run.head_sha")
if 'app-token' not in str(w.get('token', '')):
    sys.exit("the checkout must persist the APP token, or the tag push authenticates as "
             "GITHUB_TOKEN and the v1 ruleset refuses it")

perms = job.get('permissions', d.get('permissions', {}))
if isinstance(perms, dict) and perms.get('contents') == 'write':
    sys.exit("GITHUB_TOKEN must not carry contents: write -- the app token moves the tag")
PYCHK
)"; then
  fail "$err"
else
  pass "the checkout pins workflow_run.head_sha, persists the app token, and GITHUB_TOKEN has no contents: write"
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
    echo '{"job":"checks"}' > "$S_CONTRACT"
    echo base > f; git add -A; git commit -qm base
    [ "$have_v1" = no ] || git tag "$S_TAG"
    if [ "$changed" = yes ]; then echo '{"job":"checks","inputs":["new"]}' > "$S_CONTRACT"; fi
    echo more >> f; git add -A; git commit -qm next
    # A THIRD commit that touches only f, never the contract file. Without this, v1 and HEAD~1 are
    # the SAME commit (whichever one "next" is) and the sticky-comparison-base scenarios below cannot
    # tell "compared against v1" apart from "compared against the previous commit" — see the comment
    # at the call site.
    if [ "$extra" = yes ]; then echo unrelated >> f; git add -A; git commit -qm later; fi
  )
  local target; target="$(git -C "$d" rev-parse HEAD)"
  # $DECIDE is already absolute (mktemp), so it survives the cd.
  ( cd "$d" && TAG="$S_TAG" CONTRACT="$S_CONTRACT" DISPATCHED_TAG="$S_TAG" ACKNOWLEDGED="$ack" TARGET_SHA="$target" GITHUB_OUTPUT="$d/out" \
      bash "$DECIDE" >/dev/null 2>&1 ) || rc=$?
  assert_eq "$want" "$rc" "$msg"
  rm -rf "$d"
}

echo "advance-v1: the tripwire refuses on a moved contract and keeps refusing"
S_TAG=v1; S_CONTRACT=.github/reusable-contract.json
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
    echo '{"job":"checks"}' > "$S_CONTRACT"
    echo base > f; git add -A; git commit -qm base
    git tag "$S_TAG"
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
  ( cd "$d" && TAG="$S_TAG" CONTRACT="$S_CONTRACT" DISPATCHED_TAG="$S_TAG" ACKNOWLEDGED=true TARGET_SHA="$target" GITHUB_OUTPUT="$d/out" \
      bash "$DECIDE" >/dev/null 2>&1 ) || rc=$?
  assert_eq "$want" "$rc" "$msg"
  rm -rf "$d"
}

echo "advance-v1: an acknowledged dispatch still must name a commit that is actually on main"
scenario_ancestry "acknowledged dispatch, SHA is on main -> advance"                0 yes
scenario_ancestry "acknowledged dispatch, SHA is NOT an ancestor of main -> REFUSE" 1 no

# ACKNOWLEDGED MUST NOT SKIP TAG RESOLUTION. The move step ends in `git tag -f "${TAG}"` + a force
# push, and a force push of a tag that does not exist yet CREATES it — outside the one-time hand cut
# that also puts it under its ruleset. So an acknowledged dispatch for python-ci-v1 before that hand
# cut would mint an UNPROTECTED moving tag that every python-ci consumer then trusts.
echo "advance-v1: an acknowledged dispatch still refuses when the tag does not resolve"
scenario "acknowledged, v1 does not resolve -> REFUSE, do not create it" 1 true no no

echo "advance: the python-ci-v1 row runs the same tripwire against its OWN golden"
S_TAG=python-ci-v1; S_CONTRACT=.github/reusable-contract-python-ci.json
scenario "python-ci: contract unchanged since python-ci-v1 -> advance"       0 false no  yes
scenario "python-ci: contract changed since python-ci-v1 -> REFUSE"          1 false yes yes
scenario "python-ci: unrelated push after a refused one -> STILL REFUSE"     1 false yes yes yes
scenario "python-ci: python-ci-v1 does not resolve -> REFUSE, do not guess"  1 false no  no
scenario "python-ci: acknowledged additive change -> advance"                0 true  yes yes
scenario "python-ci: acknowledged BEFORE the hand cut -> REFUSE, do not create it" 1 true no no
scenario_ancestry "python-ci: acknowledged, SHA NOT on main -> REFUSE"       1 no
S_TAG=v1; S_CONTRACT=.github/reusable-contract.json

# A DISPATCH ACKNOWLEDGES ONE TAG. The matrix runs both rows on every dispatch; the row the
# acknowledgement is NOT for must do nothing — not advance on an acknowledgement meant for the
# other workflow, and not fail either.
echo "advance: a dispatch for one tag leaves the other alone"
d="$(mktemp -d)"
( cd "$d" && git init -q . && git symbolic-ref HEAD refs/heads/main && git config user.email t@t && git config user.name t \
  && git remote add origin "$d" && echo x > f && git add -A && git commit -qm x && git tag v1 )
rc=0
( cd "$d" && TAG=v1 CONTRACT=.github/reusable-contract.json DISPATCHED_TAG=python-ci-v1 ACKNOWLEDGED=true \
    TARGET_SHA="$(git rev-parse HEAD)" GITHUB_OUTPUT="$d/out" bash "$DECIDE" >/dev/null 2>&1 ) || rc=$?
assert_eq 0 "$rc" "the v1 row exits 0 on a python-ci-v1 dispatch"
assert_eq "advance=false" "$(cat "$d/out" 2>/dev/null)" "and decides NOT to advance"
rm -rf "$d"

# ...AND IT DOES SO BEFORE ANY FETCH IN THE DECIDE STEP. `origin` here is a path that does not
# exist, so any fetch fails and the decide step refuses (rc 1). A row that skipped only AFTER
# fetching would turn every dispatch red on the row nobody asked about whenever the fetch flakes.
# The app-token mint and the full checkout still run first in that row — this is about the decide
# step's OWN fetches, not about the job touching no network at all.
echo "advance: the other-tag skip runs before any fetch"
d="$(mktemp -d)"
( cd "$d" && git init -q . && git symbolic-ref HEAD refs/heads/main && git config user.email t@t && git config user.name t \
  && git remote add origin "$d/does-not-exist" && echo x > f && git add -A && git commit -qm x )
rc=0
( cd "$d" && TAG=python-ci-v1 CONTRACT=.github/reusable-contract-python-ci.json DISPATCHED_TAG=v1 ACKNOWLEDGED=true \
    TARGET_SHA="$(git rev-parse HEAD)" GITHUB_OUTPUT="$d/out" bash "$DECIDE" >/dev/null 2>&1 ) || rc=$?
assert_eq 0 "$rc" "the python-ci-v1 row exits 0 on a v1 dispatch with an unreachable origin"
assert_eq "advance=false" "$(cat "$d/out" 2>/dev/null)" "and decides NOT to advance"
# The contrast case, so the unreachable origin is shown to be a real failure: the row the dispatch IS
# for must refuse on it. "I could not fetch" is not "nothing changed".
rc=0; rm -f "$d/out"
( cd "$d" && TAG=v1 CONTRACT=.github/reusable-contract.json DISPATCHED_TAG=v1 ACKNOWLEDGED=true \
    TARGET_SHA="$(git rev-parse HEAD)" GITHUB_OUTPUT="$d/out" bash "$DECIDE" >/dev/null 2>&1 ) || rc=$?
assert_eq 1 "$rc" "the dispatched row REFUSES when the fetch fails"
assert_eq "" "$(cat "$d/out" 2>/dev/null)" "and writes no advance=true"
rm -rf "$d"

# THE POINT-TAG NUMBERING IS THE PART THE PARAMETERISATION CAN BREAK. `v1.*.0` must not count
# python-ci-v1.N.0, and python-ci-v1's sequence must not continue from v1's. Drive the real move
# step against a repo whose origin is itself, so its pushes land locally.
echo "advance: each tag numbers its own point tags"
MOVE="$(mktemp)"
python3 - "$WORKFLOW" > "$MOVE" <<'PY' || fail "advance-v1.yml must contain a step named 'move the tag and cut the next point tag'"
import sys, yaml
for s in yaml.safe_load(open(sys.argv[1]))['jobs']['advance']['steps']:
    if s.get('name') == 'move the tag and cut the next point tag':
        sys.stdout.write(s['run']); break
else:
    sys.exit("no step named 'move the tag and cut the next point tag'")
PY
d="$(mktemp -d)"
( cd "$d" && git init -q . && git symbolic-ref HEAD refs/heads/main && git config user.email t@t && git config user.name t \
  && git remote add origin "$d" && echo x > f && git add -A && git commit -qm x \
  && git tag v1.3.0 && git tag python-ci-v1.1.0 && git tag python-ci-v1.7.0 )
sha="$(git -C "$d" rev-parse HEAD)"
( cd "$d" && TAG=v1 TARGET_SHA="$sha" bash "$MOVE" >/dev/null 2>&1 ) || true
( cd "$d" && TAG=python-ci-v1 TARGET_SHA="$sha" bash "$MOVE" >/dev/null 2>&1 ) || true
assert_ok "v1 cut v1.4.0 (python-ci-v1.7.0 did not count)" git -C "$d" rev-parse -q --verify refs/tags/v1.4.0
assert_ok "python-ci-v1 cut python-ci-v1.8.0 (v1.3.0 did not count)" git -C "$d" rev-parse -q --verify refs/tags/python-ci-v1.8.0
assert_ok "the moving python-ci-v1 tag exists" git -C "$d" rev-parse -q --verify refs/tags/python-ci-v1
rm -rf "$d" "$MOVE"

# THE MATRIX IS THE ONLY PLACE A TAG NAME MAY LIVE. Every check below reads the parsed YAML. A tag or
# a golden path hard-coded into a shell body is the regression the parameterisation invites: the
# python-ci-v1 row would then diff v1's golden, or force-move v1, while every scenario above (which
# sets TAG/CONTRACT itself) stays green.
#
# BARE_V1 is a `v1` that is not part of `${TAG}`, `python-ci-v1`, or a `v1.N.0` point-tag pattern.
BARE_V1='(^|[^A-Za-z0-9_.{-])v1([^A-Za-z0-9_.-]|$)'
echo "advance: the bare-v1 detector itself catches a leftover literal and spares the parameterised text"
# shellcheck disable=SC2016  # literal workflow text, deliberately unexpanded
for bad in 'git tag -f v1 "${TARGET_SHA}"' 'git push --force origin refs/tags/v1' \
           "base=\"\$(git rev-parse -q --verify 'refs/tags/v1^{commit}')\"" 'echo "moved v1"'; do
  assert_match "catches: $bad" "$BARE_V1" "$bad"
done
# shellcheck disable=SC2016  # literal workflow text, deliberately unexpanded
for good in 'git tag -f "${TAG}" "${TARGET_SHA}"' 'python-ci-v1' "git tag -l 'v1.*.0'"; do
  assert_nomatch "spares: $good" "$BARE_V1" "$good"
done

echo "advance: the matrix, the input and the step env are exactly what the two rows need"
# Each line of output is "PASS <msg>" or "FAIL <msg>"; anything else (a traceback) counts as a fail.
structural="$(BARE_V1="$BARE_V1" python3 - "$WORKFLOW" 2>&1 <<'PY'
import json, os, re, sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
def check(ok, msg): print(("PASS " if ok else "FAIL ") + msg)
job = d['jobs']['advance']
strat = job.get('strategy', {})
want = [{"contract": ".github/reusable-contract.json", "tag": "v1"},
        {"contract": ".github/reusable-contract-python-ci.json", "tag": "python-ci-v1"}]
got = strat.get('matrix', {}).get('include')
check(json.dumps(got, sort_keys=True) == json.dumps(want, sort_keys=True),
      "matrix.include is exactly the v1 and python-ci-v1 rows (got %s)" % json.dumps(got, sort_keys=True))
check(strat.get('fail-fast') is False, "fail-fast is false, so a red row never cancels the other")

# PyYAML reads the bare key `on` as boolean True.
on = d.get('on', d.get(True, {}))
inputs = on['workflow_dispatch']['inputs']
tag_in = inputs.get('tag', {})
check(tag_in.get('type') == 'choice' and tag_in.get('required') is True
      and tag_in.get('options') == ['v1', 'python-ci-v1'],
      "the dispatch input `tag` is a required choice of exactly [v1, python-ci-v1]")
check(list(inputs).index('tag') < list(inputs).index('acknowledge-contract-change') if 'tag' in inputs else False,
      "`tag` sits above `acknowledge-contract-change`")

steps = job['steps']
dec = next((s for s in steps if s.get('id') == 'decide'), {})
mov = next((s for s in steps if s.get('name') == 'move the tag and cut the next point tag'), {})
de, me = dec.get('env', {}), mov.get('env', {})
check(de.get('TAG') == '${{ matrix.tag }}', "decide env TAG is ${{ matrix.tag }}")
check(de.get('CONTRACT') == '${{ matrix.contract }}', "decide env CONTRACT is ${{ matrix.contract }}")
check(de.get('DISPATCHED_TAG') == '${{ inputs.tag }}', "decide env DISPATCHED_TAG is ${{ inputs.tag }}")
check(me.get('TAG') == '${{ matrix.tag }}', "move env TAG is ${{ matrix.tag }}")

bare = re.compile(os.environ['BARE_V1'])
for name, step in (('decide', dec), ('move', mov)):
    check(bool(step.get('run')), "the %s step exists, so the checks on its body are not vacuous" % name)
    body = [l for l in step.get('run', '').splitlines() if not l.lstrip().startswith('#')]
    hits = [l.strip() for l in body if bare.search(l)]
    check(not hits, "the %s body names no bare v1 (found: %s)" % (name, hits))
    lits = [l.strip() for l in body if '.github/reusable-contract.json' in l]
    check(not lits, "the %s body names no literal golden path (found: %s)" % (name, lits))

pushes = [l.strip() for l in mov.get('run', '').splitlines()
          if not l.lstrip().startswith('#') and 'git push' in l]
allowed = {'git push origin "refs/tags/${next}"', 'git push --force origin "refs/tags/${TAG}"'}
check(len(pushes) == 2 and set(pushes) == allowed,
      "the move body pushes ONLY refs/tags/${next} and (forced) refs/tags/${TAG} (got %s)" % pushes)
PY
)" || structural="${structural}
FAIL the structural check crashed"
while IFS= read -r line; do
  case "$line" in
    "PASS "*) pass "${line#PASS }" ;;
    *)        fail "${line#FAIL }" ;;
  esac
done <<<"$structural"

finish
