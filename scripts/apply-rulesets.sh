#!/usr/bin/env bash
#
# Apply branch protection where the GitHub plan allows it, and say plainly where it does not.
#
#   ./scripts/apply-rulesets.sh [--org] [--dry-run]
#
# Branch protection and rulesets are UNAVAILABLE on private repos on the Free plan — for
# everyone, including org owners. Org-level rulesets additionally require Team. This script
# never pretends otherwise: if it cannot protect a branch, it says so and exits 0.
#
set -euo pipefail

ORG="Avenue-Z"
DO_ORG=0
DRY=0

warn() { printf '\033[33mSKIP\033[0m  %s\n' "$*"; }
info() { printf '\033[32m--\033[0m    %s\n' "$*"; }
die()  { printf '\033[31mERROR\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --org)     DO_ORG=1; shift ;;
    --dry-run) DRY=1; shift ;;
    *)         die "unknown flag '$1'" ;;
  esac
done

PLAN="$(gh api "orgs/${ORG}" -q .plan.name 2>/dev/null || echo unknown)"
info "org plan: ${PLAN}"

# ------------------------------------------------------------------ org ruleset
if [ "${DO_ORG}" -eq 1 ]; then
  if [ "${PLAN}" = free ]; then
    warn "org-level rulesets require GitHub Team. On Free they cannot be created."
    warn "  The ruleset is committed at .github/rulesets/org-ruleset.json, ready to apply on upgrade."
    exit 0
  fi
  if [ "${DRY}" -eq 1 ]; then
    info "[dry-run] would POST orgs/${ORG}/rulesets from .github/rulesets/org-ruleset.json"
    exit 0
  fi
  gh api -X POST "orgs/${ORG}/rulesets" --input .github/rulesets/org-ruleset.json \
    || die "org ruleset failed. Need the admin:org scope? gh auth refresh -h github.com -s admin:org"
  info "org ruleset applied — every repo in ${ORG} now inherits it."
  exit 0
fi

# ----------------------------------------------------------------- repo ruleset
# Compute which status checks would be required. This is a purely local decision — it only
# depends on whether ci.yml exists in this working copy — so it is computed and shown up
# front, regardless of whether we can even reach GitHub to find out what repo we're in.
#
# Add 'ci' to the required checks ONLY if ci.yml is actually present. A required check
# that never reports does not fail the PR — it hangs PENDING forever, and nothing merges.
PAYLOAD="$(mktemp)"; trap 'rm -f "${PAYLOAD}"' EXIT
if [ -f .github/workflows/ci.yml ]; then
  info "ci.yml present — adding 'ci' to required checks"
  jq '(.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks)
      += [{"context":"ci"}]' .github/rulesets/repo-ruleset.json > "${PAYLOAD}"
else
  info "no ci.yml (stack-agnostic core) — requiring only guard-base-branch + secret-scan"
  info "  A required 'ci' check would hang pending forever and make every PR unmergeable."
  cp .github/rulesets/repo-ruleset.json "${PAYLOAD}"
fi
info "required status checks:"
jq -r '.rules[] | select(.type=="required_status_checks")
       | .parameters.required_status_checks[].context' "${PAYLOAD}" | sed 's/^/        required: /'

# Figure out which repo we're targeting. This requires a GitHub remote — if this working
# copy has none yet (e.g. it hasn't been pushed), say so plainly and stop. That is not a
# script bug; it's an honest report that there is nothing to apply protection to yet.
if ! REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)"; then
  warn "cannot determine target repo — no GitHub remote is configured for this working copy."
  warn "  Nothing was applied. This is expected before the repo is pushed to GitHub."
  exit 0
fi
VIS="$(gh repo view --json visibility -q .visibility)"
info "repo: ${REPO} (${VIS})"

if [ "${VIS}" != "PUBLIC" ] && [ "${PLAN}" = free ]; then
  warn "${REPO} is PRIVATE and ${ORG} is on the Free plan."
  warn "  Branch protection and rulesets are UNAVAILABLE here. Nothing was applied."
  warn "  main/staging/dev are NOT protected. A direct push to main will succeed."
  warn "  Enforcement in this repo is: guard-base-branch + secret-scan on PRs, and convention."
  warn "  To get real protection: upgrade ${ORG} to GitHub Team, then run: $0 --org"
  exit 0                       # NOT an error — an honest report of a plan limit.
fi

if [ "${DRY}" -eq 1 ]; then
  info "[dry-run] would POST repos/${REPO}/rulesets with the required checks listed above"
  exit 0
fi

gh api -X POST "repos/${REPO}/rulesets" --input "${PAYLOAD}" >/dev/null \
  || die "ruleset POST failed for ${REPO}"
info "ruleset applied to ${REPO} on main, staging, dev."
info "Verify you can still merge:  gh api repos/${REPO}/branches/main/protection"
