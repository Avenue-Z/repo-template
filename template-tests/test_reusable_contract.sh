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
# The three things a consumer can observe are the job key (it IS the context, as `<caller>/<called>`),
# the triggers, and the declared inputs/secrets. Nothing else here is a contract.

echo "reusable contract: the golden file and the workflow both exist"
assert_file "the golden contract file exists" "$GOLDEN"
assert_file "the workflow exists" "$WORKFLOW"

actual="$(python3 - "$WORKFLOW" <<'PY'
import json, sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
# PyYAML resolves an unquoted `on:` key to the BOOLEAN True (the YAML 1.1 y/n/on/off rule). Reading
# d['on'] therefore returns None on a perfectly valid workflow, and every trigger assertion below
# would pass vacuously against an empty list. Accept either key.
on = d.get('on', d.get(True)) or {}
jobs = list(d.get('jobs', {}))
call = (on.get('workflow_call') or {}) if isinstance(on, dict) else {}
print(json.dumps({
    "job": jobs[0] if len(jobs) == 1 else "|".join(jobs),
    "on": sorted(on) if isinstance(on, dict) else sorted(on if isinstance(on, list) else [on]),
    "inputs": sorted((call.get('inputs') or {})),
    "secrets": sorted((call.get('secrets') or {})),
}, sort_keys=True, separators=(',', ':')))
PY
)"
expected="$(jq -Sc 'del(._comment)' "$GOLDEN")"

echo "reusable contract: checks.yml matches the golden EXACTLY (additions included, not just removals)"
assert_eq "$expected" "$actual" "the consumer-visible surface of checks.yml == .github/reusable-contract.json"

# Spelled out separately so a failure names the thing that broke rather than printing two JSON blobs.
echo "reusable contract: the three properties, individually"
assert_eq "checks" "$(jq -r '.job' <<<"$actual")" "the job key is literally 'checks' (it IS the context)"
assert_match "on: declares workflow_call (consumers call it)"  'workflow_call'  "$(jq -r '.on|join(" ")' <<<"$actual")"
# This is the assertion that catches the silent-failure path a second time, from a different angle:
# if someone strips pull_request while tidying checks.yml into a "pure" reusable workflow, every
# newly generated repo ships a workflow with no triggers that enforces nothing and reports nothing.
assert_match "on: still declares pull_request (it guards repo-template itself)" 'pull_request' "$(jq -r '.on|join(" ")' <<<"$actual")"
assert_match "on: still declares the weekly audit"             'schedule'       "$(jq -r '.on|join(" ")' <<<"$actual")"

echo "reusable contract: the self-call gates the tag (layer 2 of the spec's §4)"
TT=.github/workflows/template-tests.yml
tt="$(cat "$TT")"
# It must live INSIDE template-tests.yml. advance-v1.yml chains off the template-tests workflow RUN,
# so a self-call published as its own workflow would not gate anything and v1 could advance carrying a
# reusable workflow that is not callable at all — the one failure this layer exists to catch.
assert_match "template-tests.yml calls checks.yml locally" 'uses: \./\.github/workflows/checks\.yml' "$tt"
# Push-only. On every PR it would be one extra billed job per PR across the fleet, in a design whose
# premise is that job COUNT is the bill.
assert_match "the self-call runs on push, not on every PR" "github\.event_name == 'push'" "$tt"

finish
