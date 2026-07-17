#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=template-tests/lib.sh disable=SC1091
source template-tests/lib.sh

# =======================================================================================
# Item 4 Part A — Bandit SAST. The BLOCK RULE is the whole point and it lives in a test,
# not in prose: scripts/bandit-gate.sh is driven with recorded Bandit-shaped JSON and the
# EXIT CODE is asserted. Block ONLY on HIGH severity AND HIGH confidence, and ONLY on the
# 'client-facing' tier (read from Item 1's shared .github/sca-policy.json).

GATE=scripts/bandit-gate.sh
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# --- policy fixtures (reuse Item 1's schema: {"tier": ...}) -----------------------------
printf '{"tier":"client-facing"}\n' > "$TMP/client.json"
printf '{"tier":"internal"}\n'      > "$TMP/internal.json"
printf '{"nope":true}\n'            > "$TMP/malformed.json"   # no tier -> must default to strict

# --- bandit report fixtures (shape of `bandit -f json`: results[].issue_severity/_confidence) ---
mk() { # <severity> <confidence> -> a one-finding bandit report on stdout
  printf '{"errors":[],"results":[{"test_id":"B602","test_name":"x","filename":"src/app/a.py","line_number":3,"issue_severity":"%s","issue_confidence":"%s","issue_text":"t"}]}\n' "$1" "$2"
}
mk HIGH HIGH   > "$TMP/high_high.json"
mk HIGH LOW    > "$TMP/high_low.json"     # confidence axis: severity high, confidence low -> no block
mk LOW  HIGH   > "$TMP/low_high.json"     # severity axis: confidence high, severity low  -> no block
mk MEDIUM MEDIUM > "$TMP/med_med.json"
printf '{"errors":[],"results":[]}\n' > "$TMP/clean.json"

gate_rc() { local rc=0; "$GATE" "$1" "$2" >/dev/null 2>&1 || rc=$?; echo "$rc"; }

echo "bandit-gate: block ONLY on high severity AND high confidence, ONLY on client-facing"
assert_eq 1 "$(gate_rc "$TMP/high_high.json" "$TMP/client.json")"   "client-facing blocks a HIGH-severity + HIGH-confidence finding"
assert_eq 0 "$(gate_rc "$TMP/high_high.json" "$TMP/internal.json")" "internal only warns on the same high/high finding"
assert_eq 0 "$(gate_rc "$TMP/high_low.json"  "$TMP/client.json")"   "client-facing does NOT block HIGH severity + LOW confidence (confidence axis)"
assert_eq 0 "$(gate_rc "$TMP/low_high.json"  "$TMP/client.json")"   "client-facing does NOT block LOW severity + HIGH confidence (severity axis)"
assert_eq 0 "$(gate_rc "$TMP/med_med.json"   "$TMP/client.json")"   "client-facing does NOT block a MEDIUM/MEDIUM finding"
assert_eq 0 "$(gate_rc "$TMP/clean.json"     "$TMP/client.json")"   "a clean report (no findings) passes"
assert_eq 1 "$(gate_rc "$TMP/high_high.json" "$TMP/malformed.json")" "a policy with no valid tier defaults to client-facing (strict) and still blocks (fail-safe)"
assert_eq 0 "$(gate_rc "$TMP/does-not-exist.json" "$TMP/client.json")" "a missing/empty bandit report passes (nothing to gate)"

# --- design §Testing (b): reads its TIER from Item 1's committed policy file, no 2nd tier dial ---
echo "bandit-gate: reads the shared Item 1 policy file; adds no second tier file"
assert_match "bandit-gate.sh reads .github/sca-policy.json"  '\.github/sca-policy\.json' "$(cat "$GATE")"
assert_no_file "Part A must NOT introduce a second policy/tier file" .github/security-policy.json
assert_file   "the shared Item 1 policy file is present on the base branch" .github/sca-policy.json
assert_eq "client-facing" "$(jq -r '.tier' .github/sca-policy.json)" "the shipped shared tier is the fail-safe 'client-facing'"

# --- fidelity: if real bandit is available, prove our fixtures match its actual JSON schema ---
echo "bandit-gate: real-bandit fidelity (skipped if bandit is not installed)"
if command -v bandit >/dev/null 2>&1; then
  mkdir -p "$TMP/proj"
  # B602 (subprocess with shell=True) is Bandit HIGH severity / HIGH confidence.
  printf 'import subprocess\ndef run(c):\n    subprocess.Popen(c, shell=True)\n' > "$TMP/proj/x.py"
  bandit -r "$TMP/proj" -f json -o "$TMP/real.json" >/dev/null 2>&1 || true
  assert_eq "HIGH" "$(jq -r '[.results[]|select(.issue_severity=="HIGH" and .issue_confidence=="HIGH")][0].issue_severity // "NONE"' "$TMP/real.json")" "real bandit emits a HIGH/HIGH finding for shell=True (schema matches our fixtures)"
  assert_eq 1 "$(gate_rc "$TMP/real.json" "$TMP/client.json")" "the gate blocks a REAL bandit high/high report on client-facing"
else
  skip "bandit not installed — schema-fidelity check not run"
fi

finish
