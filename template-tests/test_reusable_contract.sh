#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=template-tests/lib.sh disable=SC1091
source template-tests/lib.sh

WORKFLOW=.github/workflows/checks.yml
GOLDEN=.github/reusable-contract.json

# LAYER 3 OF THE v1 GATE (spec §4). Eleven repos execute this workflow as their only security gate,
# and v1 advances automatically. This suite does NOT know whether a change is breaking. It knows the
# consumer-visible surface MOVED, and forces a human to say which it is — the same job the ShellCheck
# gate does for lint discipline: convert a rule that lives in one maintainer's head into a red test.
#
# The four things a consumer can observe are the job key (it IS the context, as `<caller>/<called>`),
# the triggers, the declared inputs/secrets, and the permissions the `checks` job requests. Nothing else
# here is a contract.
#
# PERMISSIONS ARE CONTRACT BECAUSE EVERY CALLER MUST GRANT THEM. Permissions along a reusable-workflow
# call chain can be kept or reduced, never elevated, so a permission checks.yml newly requests is one
# every existing caller lacks -- and that does not produce a red check. The call is refused when GitHub
# expands it: startup_failure, zero jobs, no `checks / checks` context, and a required check that hangs
# PENDING FOREVER. `id-token: write` went out as v1.4.0 exactly this way, unrefused, because this suite
# did not look. What is recorded is the `checks` job's EFFECTIVE block: its own `permissions:` if it
# has one (a job block REPLACES the workflow default), otherwise the workflow's.

echo "reusable contract: the golden file and the workflow both exist"
assert_file "the golden contract file exists" "$GOLDEN"
assert_file "the workflow exists" "$WORKFLOW"

surface() { # <workflow> <job> -- the consumer-visible surface as canonical JSON
  python3 - "$1" "$2" <<'PY'
import json, sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
# PyYAML resolves an unquoted `on:` key to the BOOLEAN True (the YAML 1.1 y/n/on/off rule). Reading
# d['on'] therefore returns None on a perfectly valid workflow, and every trigger assertion below
# would pass vacuously against an empty list. Accept either key.
on = d.get('on', d.get(True)) or {}
jobs = list(d.get('jobs', {}))
call = (on.get('workflow_call') or {}) if isinstance(on, dict) else {}
job = d.get('jobs', {}).get(sys.argv[2]) or {}
perms = job['permissions'] if 'permissions' in job else d.get('permissions')
inputs = sorted(
    ({"name": k, **{f: v[f] for f in ("type", "required", "default") if f in (v or {})}}
     for k, v in (call.get('inputs') or {}).items()),
    key=lambda i: i["name"])
print(json.dumps({
    "job": jobs[0] if len(jobs) == 1 else "|".join(jobs),
    "permissions": perms,
    "on": sorted(on) if isinstance(on, dict) else sorted(on if isinstance(on, list) else [on]),
    "inputs": inputs,
    "secrets": sorted((call.get('secrets') or {})),
}, sort_keys=True, separators=(',', ':')))
PY
}

actual="$(surface "$WORKFLOW" checks)"
expected="$(jq -Sc 'del(._comment)' "$GOLDEN")"

echo "reusable contract: checks.yml matches the golden EXACTLY (additions included, not just removals)"
assert_eq "$expected" "$actual" "the consumer-visible surface of checks.yml == .github/reusable-contract.json"

# Spelled out separately so a failure names the thing that broke rather than printing two JSON blobs.
echo "reusable contract: the properties, individually"
assert_eq "checks" "$(jq -r '.job' <<<"$actual")" "the job key is literally 'checks' (it IS the context)"
assert_match "on: declares workflow_call (consumers call it)"  'workflow_call'  "$(jq -r '.on|join(" ")' <<<"$actual")"
# This is the assertion that catches the silent-failure path a second time, from a different angle:
# if someone strips pull_request while tidying checks.yml into a "pure" reusable workflow, every
# newly generated repo ships a workflow with no triggers that enforces nothing and reports nothing.
assert_match "on: still declares pull_request (it guards repo-template itself)" 'pull_request' "$(jq -r '.on|join(" ")' <<<"$actual")"
assert_match "on: still declares the weekly audit"             'schedule'       "$(jq -r '.on|join(" ")' <<<"$actual")"
# Named on its own because it is the one permission the whole consumer path depends on: without it the
# staging step cannot read the OIDC job_workflow_ref claim, and every consumer's gate refuses.
assert_eq "write" "$(jq -r '.permissions."id-token" // "ABSENT"' <<<"$actual")" \
  "the checks job requests id-token: write (callers must grant it; recorded in the golden as contract)"

echo "reusable contract: the self-call gates the tag (layer 2 of the spec's §4)"
TT=.github/workflows/template-tests.yml
# It must live INSIDE template-tests.yml. advance-v1.yml chains off the template-tests workflow RUN,
# so a self-call published as its own workflow would not gate anything and v1 could advance carrying a
# reusable workflow that is not callable at all — the one failure this layer exists to catch.
#
# STRUCTURAL, not a grep of the whole file. A plain `assert_match` here is satisfied by these two
# strings sitting in a COMMENT above a self-call job that was gutted to `runs-on: ubuntu-latest` /
# `steps: - run: echo noop` (no `uses:` at all) with no `if:` restricting it to push — proven by
# perturbation, and both grep-based assertions still passed. Parse the YAML and read the
# self-call JOB'S OWN keys instead of the file's text.
self_call="$(python3 - "$TT" <<'PY'
import json, sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
job = d.get('jobs', {}).get('self-call') or {}
print(json.dumps({"uses": job.get('uses'), "if": job.get('if'),
                  "perms": job.get('permissions') or {}}))
PY
)"
assert_eq "./.github/workflows/checks.yml" "$(jq -r '.uses' <<<"$self_call")" \
  "the self-call job itself 'uses' checks.yml (not just mentioned in a comment)"
# Push-only. On every PR it would be one extra billed job per PR across the fleet, in a design whose
# premise is that job COUNT is the bill.
assert_eq "github.event_name == 'push'" "$(jq -r '.if' <<<"$self_call")" \
  "the self-call job's own 'if' restricts it to push (not just mentioned in a comment)"
# THE SELF-CALL IS A CALLER AND IS BOUND BY EVERY RULE A CONSUMER'S CALLER IS. checks.yml requests
# id-token: write (it reads its own ref from the OIDC job_workflow_ref claim); a caller granting less
# is an ELEVATION, and that does not fail the JOB -- it fails the whole WORKFLOW at startup, with
# zero jobs and no context reported. `if:` does not save it: the elevation is caught when the call is
# expanded, before the condition is ever evaluated, so a PR that never runs the self-call still turns
# the REQUIRED template-tests check into a startup_failure. Measured here: run 34709475980 died this
# way on the very commit that added the permission to checks.yml.
sc_perms="$(jq -c '.perms' <<<"$self_call")"
assert_eq "write" "$(jq -r '."id-token" // "ABSENT"' <<<"$sc_perms")" \
  "the self-call job grants id-token: write (checks.yml requests it; granting less kills the workflow at startup)"
assert_eq "read" "$(jq -r '.contents // "ABSENT"' <<<"$sc_perms")" \
  "the self-call job still grants contents: read (a job block REPLACES the workflow-level one)"

# ---------------------------------------------------------------------------------------
# THE SECOND REUSABLE WORKFLOW GETS THE SAME TRIPWIRE (spec §6: "§4's layers have to be rebuilt for
# this workflow, not assumed to transfer"). advance-v1.yml's python-ci-v1 row compares THIS golden.
PYWF=.github/workflows/python-ci.yml
PYGOLDEN=.github/reusable-contract-python-ci.json
echo "reusable contract: python-ci.yml matches its golden EXACTLY"
assert_file "the python-ci golden exists" "$PYGOLDEN"
py_actual="$(surface "$PYWF" test)"
py_expected="$(jq -Sc 'del(._comment)' "$PYGOLDEN" 2>/dev/null || echo missing)"
assert_eq "$py_expected" "$py_actual" "the consumer-visible surface of python-ci.yml == $PYGOLDEN"
assert_eq '["workflow_call"]' "$(jq -c '.on' <<<"$py_actual")" "python-ci.yml is called, never triggered"
assert_eq "write" "$(jq -r '.permissions."id-token" // "ABSENT"' <<<"$py_actual")" \
  "python-ci.yml requests id-token: write (callers must grant it)"
assert_eq "true" "$(jq -r '.inputs[]|select(.name=="python-versions")|.required' <<<"$py_actual")" \
  "python-versions stays required (a default would move every repo's Python version into repo-template)"

finish
