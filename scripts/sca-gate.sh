#!/usr/bin/env bash
# scripts/sca-gate.sh <osv-json> <policy-json>
#
# Applies the SCA policy tier to an osv-scanner JSON report and sets the check verdict.
#
# THE INVARIANT (holds in EVERY tier): never block on a finding with no available fix. A finding
# blocks ONLY IF its severity is High/Critical AND a fixed version exists. This is what stops a new
# CVE against an already-pinned dep from making every open PR unmergeable over something nobody can
# fix — the exact pathology the design rejects.
#
#   client-facing -> exit 1 if any blocking finding exists; else 0 (warn)
#   internal      -> always exit 0 (warn only)
set -euo pipefail

OSV_JSON="${1:?usage: sca-gate.sh <osv-json> <policy-json>}"
POLICY="${2:?usage: sca-gate.sh <osv-json> <policy-json>}"

command -v jq >/dev/null 2>&1 || { echo "::error::jq is required but not installed" >&2; exit 2; }

# Fail-safe: an unreadable or tier-less policy is treated as the STRICT default, never as a bypass.
tier="$(jq -r '.tier // empty' "${POLICY}" 2>/dev/null || true)"
case "${tier}" in
  client-facing|internal) ;;
  *) echo "::warning::sca-policy tier missing/invalid ('${tier:-}') — defaulting to client-facing (strict)"; tier="client-facing" ;;
esac

# osv-scanner writes nothing (and exits 128) when it finds no packages/lockfiles. An absent or empty
# report is "nothing to scan", a clean pass — never a crash.
if [ ! -s "${OSV_JSON}" ]; then
  echo "sca: no osv-scanner report (no packages/lockfiles found) — nothing to scan"
  exit 0
fi

# All findings, for the informational warn line (every severity, regardless of threshold).
all_ids="$(jq -r '[ .results[]?.packages[]?.vulnerabilities[]? | .id ] | unique | .[]' "${OSV_JSON}")"
if [ -n "${all_ids}" ]; then
  echo "sca: findings (all severities):"
  while IFS= read -r _id; do printf '  - %s\n' "${_id}"; done <<<"${all_ids}"
fi

# A "blocking" finding = severity High/Critical AND a fix is available.
#   Severity: database_specific.severity (populated for GitHub-Advisory-sourced records — the
#     dominant case for npm/PyPI/etc). A record carrying ONLY a CVSS vector and no
#     database_specific.severity is treated as severity-unknown -> NOT blocking. That is the honest
#     conservative reading: block only on findings we can positively classify as High+, never on
#     noise. (Boundary is stated in SECURITY.md; Task 2 verifies this field is present in real output.)
#   Fix available: any affected range carrying a `fixed` event.
blocking="$(jq -r '
  [ .results[]?.packages[]?.vulnerabilities[]?
    | select( (.database_specific.severity // "" | ascii_upcase) as $s | $s == "HIGH" or $s == "CRITICAL" )
    | select( any(.affected[]?.ranges[]?.events[]?; has("fixed")) )
    | .id ]
  | unique | .[]' "${OSV_JSON}")"

if [ -z "${blocking}" ]; then
  echo "sca: no High/Critical finding with an available fix — nothing blocks (tier: ${tier})"
  exit 0
fi

echo "::group::sca: High/Critical findings WITH an available fix"
while IFS= read -r _id; do printf '  - %s\n' "${_id}"; done <<<"${blocking}"
echo "::endgroup::"

if [ "${tier}" = "client-facing" ]; then
  echo "::error::sca gate (client-facing): the finding(s) above are High/Critical AND have a fix. Bump the dependency (Dependabot may already have a PR open) to clear this check."
  exit 1
fi

echo "::warning::sca gate (internal): High/Critical findings with fixes exist, but this repo's tier is 'internal' — warning only, not blocking."
exit 0
