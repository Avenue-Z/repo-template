#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=template-tests/lib.sh disable=SC1091
source template-tests/lib.sh

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

# ---------------------------------------------------------------------------------------
# REQUIRED CONTEXT REACHABILITY.
#
# A required status check that never reports does NOT fail a PR — it hangs PENDING
# FOREVER and nothing can ever be merged. The two ways to never report:
#   1. no job of that name exists at all;
#   2. a job of that name exists but is a MATRIX job — GitHub names those contexts
#      "job (leg)", so a context named plainly "job" never appears.
# This repo already asserted (1) for guard-base-branch by hand. Below, both are asserted
# for EVERY required context, in the core rulesets and in the 'ci' context that
# apply-rulesets.sh injects into every generated stack repo.
context_reachable() { # <workflow-dir> <context>  -> exit 0 and print why, or exit 1 and print why not
  python3 - "$1" "$2" <<'PY'
import glob, os, sys, yaml

wdir, ctx = sys.argv[1], sys.argv[2]
matrix_hits = []
for wf in sorted(glob.glob(os.path.join(wdir, "*.yml")) + glob.glob(os.path.join(wdir, "*.yaml"))):
    with open(wf) as fh:
        doc = yaml.safe_load(fh) or {}
    job = (doc.get("jobs") or {}).get(ctx)
    if job is None:
        continue
    if (job.get("strategy") or {}).get("matrix"):
        matrix_hits.append(wf)
        continue
    print(f"reachable: {wf} declares a non-matrix job '{ctx}'")
    sys.exit(0)

if matrix_hits:
    print(f"UNREACHABLE: {matrix_hits[0]} declares '{ctx}' as a MATRIX job. GitHub names its "
          f"contexts '{ctx} (<leg>)' — a context named plainly '{ctx}' NEVER reports, so every "
          f"PR hangs pending forever. Add a non-matrix aggregate job named exactly '{ctx}' that "
          f"`needs` the matrix and runs with `if: always()`.")
else:
    jobs = []
    for wf in sorted(glob.glob(os.path.join(wdir, "*.yml")) + glob.glob(os.path.join(wdir, "*.yaml"))):
        with open(wf) as fh:
            doc = yaml.safe_load(fh) or {}
        jobs += list((doc.get("jobs") or {}).keys())
    print(f"UNREACHABLE: no job named '{ctx}' in {wdir} (jobs found: {sorted(jobs)}). A required "
          f"context that never reports hangs every PR pending forever.")
sys.exit(1)
PY
}

echo "rulesets: every required context resolves to a REACHABLE (existing, non-matrix) job"
for f in "$REPO_RULESET" "$ORG_RULESET"; do
  for ctx in $(jq -r '.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[].context' "$f"); do
    if out=$(context_reachable .github/workflows "$ctx" 2>&1); then
      pass "$f: context '$ctx' — $out"
    else
      fail "$f: context '$ctx' — $out"
    fi
  done
done

echo "workflows: the 'ci' context apply-rulesets.sh injects must be reachable in EVERY stack template"
# Tie the premise to the script: apply-rulesets.sh appends {"context":"ci"} to the required
# checks whenever .github/workflows/ci.yml exists. Every stack template ships one, so every
# generated repo gets a required 'ci' — which must therefore be a real, non-matrix job.
if grep -q '"context":"ci"' scripts/apply-rulesets.sh; then
  pass "apply-rulesets.sh injects a required 'ci' context (premise for the checks below)"
else
  fail "apply-rulesets.sh no longer injects 'ci' — this test's premise changed, update it"
fi
for tdir in templates/*/; do
  stack="$(basename "$tdir")"
  wdir="${tdir}.github/workflows"
  if [ ! -f "${wdir}/ci.yml" ]; then
    fail "templates/${stack} has no .github/workflows/ci.yml"
    continue
  fi
  if out=$(context_reachable "$wdir" ci 2>&1); then
    pass "templates/${stack}: required context 'ci' — $out"
  else
    fail "templates/${stack}: required context 'ci' — $out"
  fi
done

finish
