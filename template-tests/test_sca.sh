#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=template-tests/lib.sh disable=SC1091
source template-tests/lib.sh

# ---------------------------------------------------------------------------------------
# THE INVARIANT IS THE WHOLE POINT: never block on a finding with no available fix, in any
# tier. These tests drive scripts/sca-gate.sh with recorded osv-scanner-shaped JSON and assert
# the EXIT CODE — so the invariant lives in a test, not in prose (design §Testing (c)).

GATE=scripts/sca-gate.sh
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# --- policy fixtures -------------------------------------------------------------------
printf '{"tier":"client-facing"}\n' > "$TMP/client.json"
printf '{"tier":"internal"}\n'      > "$TMP/internal.json"
printf '{"nope":true}\n'            > "$TMP/malformed.json"   # no tier -> must default to strict

# --- osv report fixtures (minimal, matching results[].packages[].vulnerabilities[]) ----
cat > "$TMP/high_fixed.json" <<'JSON'
{ "results": [ { "packages": [ {
  "package": { "name": "acme", "version": "1.0.0", "ecosystem": "npm" },
  "vulnerabilities": [ {
    "id": "GHSA-high-fixed",
    "database_specific": { "severity": "HIGH" },
    "affected": [ { "ranges": [ { "type": "SEMVER", "events": [ {"introduced":"0"}, {"fixed":"1.0.1"} ] } ] } ]
  } ] } ] } ] }
JSON

cat > "$TMP/critical_nofix.json" <<'JSON'
{ "results": [ { "packages": [ {
  "package": { "name": "acme", "version": "1.0.0", "ecosystem": "npm" },
  "vulnerabilities": [ {
    "id": "GHSA-crit-nofix",
    "database_specific": { "severity": "CRITICAL" },
    "affected": [ { "ranges": [ { "type": "SEMVER", "events": [ {"introduced":"0"} ] } ] } ]
  } ] } ] } ] }
JSON

cat > "$TMP/moderate_fixed.json" <<'JSON'
{ "results": [ { "packages": [ {
  "package": { "name": "acme", "version": "1.0.0", "ecosystem": "npm" },
  "vulnerabilities": [ {
    "id": "GHSA-mod-fixed",
    "database_specific": { "severity": "MODERATE" },
    "affected": [ { "ranges": [ { "type": "SEMVER", "events": [ {"introduced":"0"}, {"fixed":"1.0.1"} ] } ] } ]
  } ] } ] } ] }
JSON

printf '{"results":[]}\n' > "$TMP/empty.json"

# run the gate, capture its exit code WITHOUT tripping set -e (the lib pattern)
gate_rc() { local rc=0; "$GATE" "$1" "$2" >/dev/null 2>&1 || rc=$?; echo "$rc"; }

echo "sca-gate: block only High+/fixable on client-facing; never block a no-fix finding"
assert_eq 1 "$(gate_rc "$TMP/high_fixed.json"     "$TMP/client.json")"    "client-facing blocks a HIGH finding that HAS a fix"
assert_eq 0 "$(gate_rc "$TMP/high_fixed.json"     "$TMP/internal.json")"  "internal only warns on the same HIGH+fix finding"
assert_eq 0 "$(gate_rc "$TMP/critical_nofix.json" "$TMP/client.json")"    "client-facing does NOT block a CRITICAL finding with NO fix (the invariant)"
assert_eq 0 "$(gate_rc "$TMP/moderate_fixed.json" "$TMP/client.json")"    "client-facing does NOT block a MODERATE finding (below the High floor)"
assert_eq 0 "$(gate_rc "$TMP/empty.json"          "$TMP/client.json")"    "an empty report passes"
assert_eq 1 "$(gate_rc "$TMP/high_fixed.json"     "$TMP/malformed.json")" "a policy with no valid tier defaults to client-facing (strict) and still blocks"
assert_eq 0 "$(gate_rc "$TMP/does-not-exist.json" "$TMP/client.json")"    "a missing/empty osv report passes (osv-scanner found no packages)"

# --- design §Testing (a): the shipped default tier is the fail-safe 'client-facing' ----
echo "sca policy: the shipped default tier is the fail-safe 'client-facing'"
assert_file "the SCA policy file exists" .github/sca-policy.json
assert_eq "client-facing" "$(jq -r '.tier' .github/sca-policy.json)" "shipped .github/sca-policy.json tier == client-facing"

# --- design §Testing (b): the policy is present AND referenced by the SCA workflow ------
echo "sca workflow: it reads the policy and runs the gate under a job named 'sca'"
WF=.github/workflows/sca.yml
assert_file "the SCA workflow exists" "$WF"
wf="$(cat "$WF")"
assert_match "sca.yml runs scripts/sca-gate.sh"           'scripts/sca-gate\.sh'      "$wf"
assert_match "sca.yml references .github/sca-policy.json"  '\.github/sca-policy\.json' "$wf"
assert_match "sca.yml declares a job keyed 'sca' (the required context must reach a real job)" '^[[:space:]]*sca:' "$wf"
assert_match "sca.yml is read-only (permissions: contents: read)" 'contents:[[:space:]]*read' "$wf"

# --- the stated boundary and the auto-remediation step are documented (not just in the plan) ---
echo "docs: the SCA tier boundary and the auto-remediation step are recorded"
assert_match "SECURITY.md states the tier-currency boundary" 'tier is only as current' "$(cat SECURITY.md)"
assert_match "ADOPTION.md documents enabling Dependabot security updates" 'automated-security-fixes' "$(cat docs/ADOPTION.md)"

finish
