#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=template-tests/lib.sh disable=SC1091
source template-tests/lib.sh

WORKFLOW=.github/workflows/checks.yml

# THE VERDICT STEP IS THE SINGLE POINT OF FAILURE FOR ALL THREE GATES.
#
# When guard-base-branch, secret-scan and sca were three workflows, each reported its own
# required context and each failed its own job. There was nothing shared to get wrong. Merging
# them into one job (to stop paying three rounded-up billed minutes for ~19 seconds of work)
# means every gate now runs under `continue-on-error: true` — so NOTHING fails the job on its
# own any more. One step at the end reads the recorded outcomes and decides.
#
# That is a new and total failure mode: break the verdict and all three controls go quiet at
# once. gitleaks still runs, still finds the key, still prints it in red — and the check goes
# GREEN. No other suite would notice. This one drives the REAL verdict block, extracted from the
# workflow, against every outcome combination the job can actually produce.

echo "checks verdict: the step exists and can be extracted from the workflow"
assert_file "$WORKFLOW exists" "$WORKFLOW"
VERDICT="$(mktemp)"; trap 'rm -f "${VERDICT}"' EXIT
python3 - "$WORKFLOW" > "$VERDICT" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for s in d['jobs']['checks']['steps']:
    if s.get('name') == 'verdict':
        sys.stdout.write(s['run']); break
else:
    sys.exit("no step named 'verdict' in checks.yml")
PY
if [ -s "$VERDICT" ]; then
  pass "the 'verdict' step's script was extracted"
else
  fail "checks.yml must contain a step named 'verdict' — without it nothing fails the job"
fi

# Stage the trusted script exactly as the workflow's own staging step does.
RT="$(mktemp -d)"; trap 'rm -f "${VERDICT}"; rm -rf "${RT}"' EXIT
mkdir -p "${RT}/trusted-scripts"
install -m 0755 scripts/ci-aggregate-gate.sh "${RT}/trusted-scripts/"

# <msg> <expected-exit> <event> <guard> <secret_scan> <sca>
verdict() {
  local msg="$1" want="$2" rc=0
  RUNNER_TEMP="${RT}" EVENT="$3" GUARD_RESULT="$4" SECRET_SCAN_RESULT="$5" SCA_RESULT="$6" \
    bash "${VERDICT}" >/dev/null 2>&1 || rc=$?
  assert_eq "$want" "$rc" "$msg"
}

echo "checks verdict: any failing gate blocks the PR; green only when all three pass"
verdict "all three pass -> the PR can merge"        0 pull_request success success success
verdict "bad branch prefix -> BLOCKED"              1 pull_request failure success success
verdict "planted secret -> BLOCKED"                 1 pull_request success failure success
verdict "vulnerable dependency -> BLOCKED"          1 pull_request success success failure
verdict "all three failing -> BLOCKED"              1 pull_request failure failure failure

# A gate that did not RUN has not PASSED. This is the fail-safe posture the SCA gate and the bandit
# step already take on a scanner error, applied to the aggregate: if an install step dies, the
# gate's outcome is 'skipped', and 'skipped' must never read as consent to merge.
echo "checks verdict: a gate that did not run is a FAILURE, not a pass"
verdict "a scanner install died (skipped) -> BLOCKED"       1 pull_request success skipped skipped
verdict "the guard skipped on a pull_request -> BLOCKED"    1 pull_request skipped success success
verdict "a cancelled gate -> BLOCKED"                       1 pull_request cancelled success success

# The guard needs a base_ref, which a scheduled run does not have, so it is skipped there BY
# DESIGN and must not be named as a gate. Getting this wrong makes the weekly audit permanently
# red for a reason nobody can fix.
#
# The cron REPLACED the old push trigger: re-scanning dev/staging/main on every merge cost ~30
# billed jobs a month to re-check commits that had just been checked as PR heads, while the thing
# those scans are actually for — full-history secret audit, and advisories published against deps
# that did not change — is time-based, not change-based.
echo "checks verdict: on the scheduled audit the guard is legitimately absent"
verdict "scheduled audit, clean -> PASS"            0 schedule skipped success success
verdict "scheduled audit finds a secret -> FAIL"    1 schedule skipped failure success
verdict "scheduled audit finds a vuln -> FAIL"      1 schedule skipped success failure
# Any non-pull_request event must take the same path — nothing here may key off the literal
# string "schedule", or a workflow_dispatch added later would silently demand an absent guard.
verdict "a manual dispatch behaves like the audit"  0 workflow_dispatch skipped success success

# On a pull_request the verdict logic MUST come from the base branch. If it came from the PR's
# own tree, a PR could rewrite ci-aggregate-gate.sh to `exit 0` and switch off the guard, the
# secret scan and the SCA gate in one line — re-opening the exact hole the base checkout exists
# to close. So a missing trusted copy must refuse to report, never fall back to the PR's copy.
echo "checks verdict: a PR with no trusted verdict script must refuse, not fall back"
rm -f "${RT}/trusted-scripts/ci-aggregate-gate.sh"
verdict "trusted verdict script missing on a PR -> BLOCKED" 1 pull_request success success success

finish
