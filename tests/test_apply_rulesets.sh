#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=tests/lib.sh disable=SC1091
source tests/lib.sh

echo "apply-rulesets: honest reporting"
if out=$(./scripts/apply-rulesets.sh --dry-run 2>&1); then
  pass "--dry-run exits 0"
else
  fail "--dry-run should exit 0 even when protection is impossible"
fi
assert_match "explains what it did or skipped" 'free|skip|cannot|unavailable|would apply' "$out"

echo "apply-rulesets: anti-brick — no ci.yml in template core means 'ci' must never be required"
if [ -f .github/workflows/ci.yml ]; then
  fail "template core unexpectedly has ci.yml — this test's premise no longer holds, update it"
else
  pass "confirmed no ci.yml present (test precondition for the anti-brick case)"
fi
assert_nomatch "'ci' is NOT listed as a required status check" 'required: ci$' "$out"
assert_match   "'guard-base-branch' is listed as required" 'required: guard-base-branch' "$out"
assert_match   "'secret-scan' is listed as required" 'required: secret-scan' "$out"

echo "apply-rulesets: --org honest reporting (org-level rulesets need GitHub Team)"
if out_org=$(./scripts/apply-rulesets.sh --org --dry-run 2>&1); then
  pass "--org --dry-run exits 0"
else
  fail "--org --dry-run should exit 0 even when Team is required"
fi
assert_match "--org explains the Team/Free limitation" 'team|free' "$out_org"

# ---------------------------------------------------------------------------------------
# CRITERION 6 — the private + Free path must be HONEST.
#
# Every run above exits early at "cannot determine target repo" (this working copy has no
# GitHub remote), so NOTHING above ever reaches the private+Free branch. That branch is the
# whole point of the script: on Free, branch protection does not exist for private repos,
# and the script must say so — "main is NOT protected, a direct push WILL succeed" — instead
# of claiming success. To actually drive it, put a fake `gh` on PATH that answers `free` for
# the plan and `PRIVATE` for the visibility. Without this, replacing the entire warning block
# with `info "protection applied."` — a script that LIES — still passed the suite.
echo "apply-rulesets: criterion 6 — private repo + Free plan reports the truth"
STUB="$(mktemp -d)"
trap 'rm -rf "${STUB}"' EXIT
cat > "${STUB}/gh" <<'STUBEOF'
#!/usr/bin/env bash
# Minimal fake gh: a private repo in an org on the Free plan.
case "$*" in
  *"orgs/Avenue-Z"*)  echo free ;;
  *nameWithOwner*)    echo "Avenue-Z/fake-private-repo" ;;
  *visibility*)       echo "PRIVATE" ;;
  *) echo "fake gh: unexpected call: gh $*" >&2; exit 1 ;;
esac
STUBEOF
chmod +x "${STUB}/gh"

if out_priv=$(PATH="${STUB}:${PATH}" ./scripts/apply-rulesets.sh --dry-run 2>&1); then
  pass "private+Free exits 0 (a plan limit is an honest report, not an error)"
else
  fail "private+Free should exit 0, got non-zero. Output: ${out_priv}"
fi
assert_match   "says main/staging/dev are NOT protected" 'not protected' "$out_priv"
assert_match   "says a direct push to main will succeed" 'direct push to main will succeed' "$out_priv"
assert_nomatch "makes no false claim of applied protection" 'ruleset applied|protection applied|now protected' "$out_priv"

finish
