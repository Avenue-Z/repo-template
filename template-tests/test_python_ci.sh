#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=template-tests/lib.sh disable=SC1091
source template-tests/lib.sh

WORKFLOW=.github/workflows/python-ci.yml
CHECKS=.github/workflows/checks.yml

# python-ci.yml IS EVERY PYTHON REPO'S CI, ONCE THE FLEET MIGRATES. A bad advance of python-ci-v1
# reddens `ci` in every Python repo at once, which is a larger blast radius than checks.yml's (spec
# §6). So this suite asserts STRUCTURE from the parsed YAML, never by grepping the file, and DRIVES
# the verdict step for real, the way test_checks_verdict.sh drives checks.yml's.
#
# Steps are located by `id:` or `name:`, never by index.

echo "python-ci: the workflow exists"
assert_file "$WORKFLOW exists" "$WORKFLOW"

facts="$(python3 - "$WORKFLOW" "$CHECKS" <<'PY'
import json, sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
checks = yaml.safe_load(open(sys.argv[2]))
on = wf.get('on', wf.get(True)) or {}
call = (on.get('workflow_call') or {}) if isinstance(on, dict) else {}
job = (wf.get('jobs') or {}).get('test') or {}
steps = job.get('steps') or []
by_id = {s['id']: s for s in steps if 'id' in s}
by_name = {s['name']: s for s in steps if 'name' in s}
cres = next((s for s in checks['jobs']['checks']['steps'] if s.get('id') == 'scripts_src'), {})
tco = next((s for s in steps if str(s.get('uses', '')).startswith('actions/checkout@')
            and (s.get('with') or {}).get('repository')), {})
strip = lambda e: str(e).strip().removeprefix('${{').removesuffix('}}').strip()
print(json.dumps({
    "on": sorted(on) if isinstance(on, dict) else [],
    "inputs": call.get('inputs') or {},
    "perms": wf.get('permissions'),
    "jobs": sorted(wf.get('jobs') or {}),
    "job_has_perms": 'permissions' in job,
    "fail_fast": (job.get('strategy') or {}).get('fail-fast'),
    "matrix": ((job.get('strategy') or {}).get('matrix') or {}).get('python-version'),
    "resolver_identical": bool(cres.get('run')) and by_id.get('scripts_src', {}).get('run') == cres.get('run'),
    "tco": {"if": tco.get('if'), **(tco.get('with') or {})},
    "stage": by_name.get('Stage the trusted scripts outside the workspace', {}),
    "check": by_id.get('check', {}),
    "bandit": by_id.get('bandit', {}),
    "install_bandit_if": strip(by_name.get('install bandit', {}).get('if', '')),
    "bandit_if": strip(by_id.get('bandit', {}).get('if', '')),
    "verdict": by_name.get('verdict', {}),
    "verdict_bandit_expected": strip((by_name.get('verdict', {}).get('env') or {}).get('BANDIT_EXPECTED', '')),
    "bandit_idx_by_id": next((i for i, s in enumerate(steps) if s.get('id') == 'bandit'), None),
    "pip_install_idx_by_run": next((i for i, s in enumerate(steps) if 'pip install -e' in str(s.get('run', ''))), None),
}))
PY
)"
f() { jq -c "$1" <<<"$facts"; }
fr() { jq -r "$1" <<<"$facts"; }

echo "python-ci: it is a template-only reusable workflow"
# workflow_call ALONE. This file never runs in repo-template except through the self-call, and
# init-repo.sh deletes it from every generated repo — a generated repo gets a caller (spec §6, D6).
assert_eq '["workflow_call"]' "$(f .on)" "on: is exactly workflow_call"

echo "python-ci: the input surface"
# python-versions is REQUIRED WITH NO DEFAULT (D1): the version lives in the caller, beside the
# Dockerfile that fixes it. A default here would put every repo's Python version in repo-template.
assert_eq '{"required":true,"type":"string"}' "$(f '.inputs["python-versions"]|{required,type,default}|with_entries(select(.value!=null))')" \
  "python-versions is a required string with no default"
assert_eq '{"default":"make check","required":false,"type":"string"}' "$(f '.inputs["check-command"]|{default,required,type}')" \
  "check-command defaults to 'make check'"
assert_eq '{"default":true,"required":false,"type":"boolean"}' "$(f '.inputs["run-bandit"]|{default,required,type}')" \
  "run-bandit is a boolean defaulting to true"
assert_eq '{"default":".","required":false,"type":"string"}' "$(f '.inputs["working-directory"]|{default,required,type}')" \
  "working-directory defaults to '.' (only the self-call sets it)"
assert_eq '["check-command","python-versions","run-bandit","working-directory"]' "$(f '.inputs|keys')" \
  "no input beyond those four (a new one moves the contract; see test_reusable_contract.sh)"

echo "python-ci: permissions"
# id-token: write for the same reason checks.yml has it: the resolver reads the OIDC claim. It must
# be declared HERE — a called workflow that declares less REDUCES the caller's grant to none.
assert_eq '{"contents":"read","id-token":"write"}' "$(f '.perms')" "workflow grants contents: read + id-token: write"
assert_eq "false" "$(f .job_has_perms)" "the test job has NO permissions block (it would REPLACE the workflow's)"

echo "python-ci: one job, and the matrix is the caller's list"
assert_eq '["test"]' "$(f .jobs)" "exactly one job, 'test'"
# The single quotes are the point: this is the literal GitHub expression the workflow must carry.
# shellcheck disable=SC2016
assert_eq '${{ fromJSON(inputs.python-versions) }}' "$(fr .matrix)" "the matrix is fromJSON(inputs.python-versions)"
assert_eq "false" "$(f .fail_fast)" "fail-fast: false (a library sees every broken version, not the first)"

echo "python-ci: the gate scripts come from the template, exactly as checks.yml gets them"
# D8. The resolver cannot be shared through a composite action (loading one needs the ref this step
# computes), so it is COPIED. Identity is asserted, which makes test_checks_staging.sh's behavioural
# coverage — the stubbed OIDC endpoint, the base64url decode, every refusal — cover this copy too.
assert_eq "true" "$(f .resolver_identical)" "the scripts_src resolver is byte-identical to checks.yml's"
assert_eq "steps.scripts_src.outputs.local == 'false'" "$(fr '.tco.if')" "the template checkout is skipped on repo-template's own runs"
assert_eq "Avenue-Z/repo-template" "$(fr '.tco.repository')" "the template checkout reads Avenue-Z/repo-template"
# The single quotes are the point: this is the literal GitHub expression the workflow must carry.
# shellcheck disable=SC2016
assert_eq '${{ steps.scripts_src.outputs.ref }}' "$(fr '.tco.ref')" "the template checkout uses the resolved ref"
assert_eq "false" "$(f '.tco["persist-credentials"]')" "the template checkout does not persist credentials"
stage_run="$(fr '.stage.run // ""')"
assert_match "staging stages bandit-gate.sh and ci-aggregate-gate.sh" 'for s in bandit-gate\.sh ci-aggregate-gate\.sh; do' "$stage_run"
assert_match "staging deletes the checked-out template before anything scans the tree" 'rm -rf \.trusted-template' "$stage_run"
# The job's default working-directory is inputs.working-directory. Staging must run at the workspace
# ROOT anyway, because `scripts/` and `.trusted-template` are there.
# The single quotes are the point: this is the literal GitHub expression the workflow must carry.
# shellcheck disable=SC2016
assert_eq '${{ github.workspace }}' "$(fr '.stage["working-directory"] // ""')" "staging runs at the workspace root"

echo "python-ci: the gates"
assert_eq "true" "$(f '.check["continue-on-error"]')" "the check step is continue-on-error (the verdict decides)"
# The single quotes are the point: this is the literal GitHub expression the workflow must carry.
# shellcheck disable=SC2016
assert_eq '${{ inputs.check-command }}' "$(fr '.check.env.CHECK_COMMAND // ""')" "the check command arrives through env, not inline"
assert_eq "true" "$(f '.bandit["continue-on-error"]')" "the bandit step is continue-on-error (the verdict decides)"
# D4, and the anti-drift half of it: the three places that decide "does bandit run in this leg" are
# one expression, compared as strings. If they drift, a leg can skip bandit while the verdict still
# expects it (red for no reason) or run it while the verdict ignores it (a finding goes GREEN).
want_if='inputs.run-bandit && matrix.python-version == fromJSON(inputs.python-versions)[0]'
assert_eq "$want_if" "$(fr .bandit_if)" "bandit runs only when enabled and only in the first listed version"
assert_eq "$want_if" "$(fr .install_bandit_if)" "the bandit install uses the same condition"
assert_eq "$want_if" "$(fr .verdict_bandit_expected)" "the verdict expects bandit under exactly that condition"
bandit_run="$(fr '.bandit.run // ""')"
# R5: strip comment lines before asserting on the run body's PATHS. A comment cannot satisfy these —
# only real code can (see the mutation below, restored, that proves it bites).
bandit_code="$(grep -vE '^[[:space:]]*#' <<<"$bandit_run")"
assert_match "bandit is judged by the STAGED gate script" '"\$\{RUNNER_TEMP\}/trusted-scripts/bandit-gate\.sh"' "$bandit_code"
assert_nomatch "bandit never runs the workspace copy of the gate" '(^|[^-])scripts/bandit-gate\.sh' "$bandit_code"
assert_match "the tier comes from the repo ROOT's policy file, whatever the working directory" \
  '\$\{GITHUB_WORKSPACE\}/\.github/sca-policy\.json' "$bandit_code"

echo "python-ci: bandit runs before pip install -e (no installed package, no PR code, can influence it)"
# Found by id (the bandit step) and by run content (the install step has no id/name), never by a
# fixed index — steps around them can be added or removed without this test moving.
bandit_idx="$(fr '.bandit_idx_by_id // "missing"')"
pip_install_idx="$(fr '.pip_install_idx_by_run // "missing"')"
assert_ok "the bandit step (id: bandit) was found" [ "$bandit_idx" != "missing" ]
assert_ok "the pip install -e step was found (by run content)" [ "$pip_install_idx" != "missing" ]
if [ "$bandit_idx" != "missing" ] && [ "$pip_install_idx" != "missing" ]; then
  assert_ok "bandit (index ${bandit_idx}) runs before pip install -e (index ${pip_install_idx})" \
    [ "$bandit_idx" -lt "$pip_install_idx" ]
fi

echo "python-ci: the check step actually runs CHECK_COMMAND"
# Nothing above executes the check step's body — the continue-on-error assertion and the env-wiring
# assertion both pass even if `eval "${CHECK_COMMAND}"` were replaced with `true`. Drive the real
# step, the same way the verdict step is driven below.
CHECK_SCRIPT="$(mktemp)"
fr '.check.run // ""' > "$CHECK_SCRIPT"
check_rc() { # <check-command>
  local rc=0
  CHECK_COMMAND="$1" bash "$CHECK_SCRIPT" >/dev/null 2>&1 || rc=$?
  echo "$rc"
}
assert_eq 0 "$(check_rc true)" "CHECK_COMMAND=true -> the check step exits 0"
assert_eq 0 "$(check_rc 'test 1 -eq 1')" "a command with args (test 1 -eq 1) -> exits 0"
assert_eq 3 "$(check_rc 'exit 3')" "CHECK_COMMAND='exit 3' -> the check step propagates the real exit code"
rm -f "$CHECK_SCRIPT"

echo "python-ci: the dead context field is not read anywhere"
assert_nomatch "no step reads github.job_workflow_ref (that context is ALWAYS empty)" \
  'github\.job_workflow_ref' "$(python3 -c 'import yaml,sys; print(yaml.safe_dump(yaml.safe_load(open(sys.argv[1]))))' "$WORKFLOW")"

# LAYER 2 (spec §4). It must be a job INSIDE template-tests.yml, because advance-v1.yml chains off
# that workflow run's conclusion: a self-call anywhere else gates nothing, and python-ci-v1 could
# advance carrying a workflow nobody can call.
echo "python-ci: the self-call gates the tag"
sc="$(python3 - .github/workflows/template-tests.yml <<'PY'
import json, sys, yaml
j = (yaml.safe_load(open(sys.argv[1])).get('jobs') or {}).get('self-call-python-ci') or {}
print(json.dumps({"uses": j.get('uses'), "if": j.get('if'), "perms": j.get('permissions'), "with": j.get('with') or {}}))
PY
)"
assert_eq "./.github/workflows/python-ci.yml" "$(jq -r .uses <<<"$sc")" "a template-tests job calls python-ci.yml"
assert_eq "github.event_name == 'push'" "$(jq -r .if <<<"$sc")" "push only (one billed job per push, not per PR)"
assert_eq '{"contents":"read","id-token":"write"}' "$(jq -c .perms <<<"$sc")" \
  "the self-call grants id-token: write (granting less is a startup_failure of ALL of template-tests)"
assert_eq "templates/python" "$(jq -r '.with["working-directory"]' <<<"$sc")" "it runs against the Python template"
dockerfile_ver="$(sed -nE 's/^FROM python:([0-9]+\.[0-9]+).*/\1/p' templates/python/Dockerfile | head -1)"
assert_eq "[\"${dockerfile_ver}\"]" "$(jq -c '.with["python-versions"]|fromjson' <<<"$sc")" \
  "it tests the version the template's Dockerfile deploys on"

# ---------------------------------------------------------------------------------------
# THE VERDICT IS THE ONLY THING THAT FAILS THE JOB. Every gate runs under continue-on-error, so a
# broken verdict turns every failure GREEN. Drive the real step against the outcomes a leg produces.
echo "python-ci verdict: driven against every outcome a leg can produce"
VERDICT="$(mktemp)"; RT="$(mktemp -d)"; trap 'rm -f "${VERDICT}"; rm -rf "${RT}"' EXIT
fr '.verdict.run // ""' > "$VERDICT"
assert_eq "always()" "$(fr '.verdict.if // ""')" "the verdict runs even after a step errored outright"
# R4: pin the verdict wiring to `.outcome`, not `.conclusion`. Under continue-on-error, `.conclusion`
# is ALWAYS 'success', which would turn every gate green while the driven verdict tests below still
# pass (they set CHECK_RESULT/BANDIT_RESULT directly). Only reading the parsed env catches that.
# The single quotes are the point: this is the literal GitHub expression the workflow must carry.
# shellcheck disable=SC2016
assert_eq '${{ steps.check.outcome }}' "$(fr '.verdict.env.CHECK_RESULT // ""')" "CHECK_RESULT is wired from steps.check.outcome, not .conclusion"
# shellcheck disable=SC2016
assert_eq '${{ steps.bandit.outcome }}' "$(fr '.verdict.env.BANDIT_RESULT // ""')" "BANDIT_RESULT is wired from steps.bandit.outcome, not .conclusion"
assert_eq "false" "$(f '.verdict["continue-on-error"] // false')" "the verdict step itself has NO continue-on-error (it must be able to fail the job)"
mkdir -p "${RT}/trusted-scripts"
install -m 0755 scripts/ci-aggregate-gate.sh "${RT}/trusted-scripts/"

verdict_rc() { # <check> <bandit-outcome> <bandit-expected> [<runner-temp>]
  local rc=0
  CHECK_RESULT="$1" BANDIT_RESULT="$2" BANDIT_EXPECTED="$3" RUNNER_TEMP="${4:-$RT}" \
    bash "$VERDICT" >/dev/null 2>&1 || rc=$?
  echo "$rc"
}
assert_eq 0 "$(verdict_rc success success true)"   "check ok, bandit ok -> green"
assert_eq 1 "$(verdict_rc failure success true)"   "check failed -> red"
assert_eq 1 "$(verdict_rc success failure true)"   "bandit failed -> red"
assert_eq 1 "$(verdict_rc success skipped true)"   "bandit expected but skipped -> red (a gate that did not run has not passed)"
assert_eq 0 "$(verdict_rc success skipped false)"  "bandit not expected in this leg, skipped -> green"
assert_eq 1 "$(verdict_rc skipped skipped false)"  "check skipped (the install died) -> red"
assert_eq 1 "$(verdict_rc success success true "$(mktemp -d)")" "no staged verdict script -> red, never a fallback"

finish
