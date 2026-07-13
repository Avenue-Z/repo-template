#!/usr/bin/env bash
#
# Apply branch protection where the GitHub plan allows it, and say plainly where it does not.
#
#   ./scripts/apply-rulesets.sh [--org [--yes]] [--dry-run]
#
# Branch protection and rulesets are UNAVAILABLE on private repos on the Free plan — for
# everyone, including org owners. Org-level rulesets additionally require Team. This script
# never pretends otherwise: if it cannot protect a branch, it says so and exits 0.
#
# --org applies org-ruleset.json to EVERY repo in the org (~64 of them, almost none generated
# from this template). It is the highest-blast-radius thing in this repo, so it does not fire
# blind: it lists the repos it would hit and demands --yes (or an interactive y) first.
#
set -euo pipefail

ORG="Avenue-Z"
DO_ORG=0
DRY=0
ASSUME_YES=0

warn() { printf '\033[33mSKIP\033[0m  %s\n' "$*"; }
info() { printf '\033[32m--\033[0m    %s\n' "$*"; }
die()  { printf '\033[31mERROR\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --org)     DO_ORG=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --yes|-y)  ASSUME_YES=1; shift ;;
    *)         die "unknown flag '$1'" ;;
  esac
done

# jq is a hard dependency (the payload is built with it). Without this check, `set -e`
# just aborts on the first jq call with no output at all and no hint why.
command -v jq >/dev/null 2>&1 || die "jq is required but not installed. Install it: brew install jq"
command -v gh >/dev/null 2>&1 || die "gh is required but not installed. Install it: brew install gh"

# EVERY plan-gated decision below hangs off this value, so a failure to GET it must not be
# laundered into a value. The old `|| echo unknown` did exactly that: auth expiry, a network
# blip or a rate limit all became "unknown", which is != "free", which SKIPS the honesty
# branch and walks straight into the POST. "I could not ask" is not "not on Free".
if ! PLAN="$(gh api "orgs/${ORG}" -q .plan.name 2>&1)"; then
  die "cannot determine the ${ORG} plan (auth? network? rate limit?): ${PLAN}
       Refusing to continue: every decision below depends on the plan, and guessing it
       wrong means either a false claim of protection or a bricked repo. Fix the cause
       (gh auth status) and re-run."
fi
[ -n "${PLAN}" ] && [ "${PLAN}" != "null" ] \
  || die "the ${ORG} plan came back empty — the token likely cannot read org details.
       Refusing to continue rather than assume you are not on Free.
       Try: gh auth refresh -h github.com -s read:org"
info "org plan: ${PLAN}"

# ------------------------------------------------------------------ org ruleset
if [ "${DO_ORG}" -eq 1 ]; then
  if [ "${PLAN}" = free ]; then
    warn "org-level rulesets require GitHub Team. On Free they cannot be created."
    warn "  The ruleset is committed at .github/rulesets/org-ruleset.json, ready to apply on upgrade."
    exit 0
  fi

  ORG_SRC=".github/rulesets/org-ruleset.json"
  ORG_NAME="$(jq -r '.name' "${ORG_SRC}")"

  # `_comment` is documentation for humans, not a GitHub API field. Strip it before sending.
  ORG_PAYLOAD="$(mktemp)"; trap 'rm -f "${ORG_PAYLOAD}"' EXIT
  jq 'del(._comment)' "${ORG_SRC}" > "${ORG_PAYLOAD}"

  # ------------------------------------------------------------- blast radius, stated first
  # This ruleset targets ~ALL repositories. Almost none of them came from this template. An
  # operator who has not internalized that is one keystroke from taking push and merge away
  # from the whole org, so SHOW the list and SAY what could go wrong before doing anything.
  if ! ORG_REPOS="$(gh api "orgs/${ORG}/repos" --paginate -q '.[].name' 2>&1)"; then
    die "cannot list the repos in ${ORG} (auth? network? rate limit?): ${ORG_REPOS}
       Refusing to continue: --org applies a ruleset to EVERY repo in the org, and this
       script will not do that without first showing you which repos those are."
  fi
  ORG_REPO_COUNT="$(printf '%s\n' "${ORG_REPOS}" | grep -c . || true)"

  printf '\n'
  info "--org applies '${ORG_NAME}' to EVERY repository in ${ORG} — ${ORG_REPO_COUNT} of them:"
  printf '%s\n' "${ORG_REPOS}" | sed 's/^/        /'
  printf '\n'
  warn "Read this before you answer:"
  warn "  * Every repo above gets enforcement=active with NO bypass actors — not even an org"
  warn "    owner can push directly to main, staging or dev afterwards. Everything goes via a PR."
  warn "  * A required status check that a repo has NO WORKFLOW FOR does not fail its PRs — it"
  warn "    hangs them PENDING FOREVER, and the repo becomes permanently UNMERGEABLE. That is"
  warn "    why org-ruleset.json ships NO required_status_checks: most repos in ${ORG} have"
  warn "    neither guard-base-branch nor secret-scan, and requiring them org-wide would brick"
  warn "    every one of those repos at once. If you re-add required checks to that file, you"
  warn "    are choosing that outcome for all ${ORG_REPO_COUNT} repos listed above."
  ORG_HAS_CHECKS="$(jq -r '[.rules[] | select(.type=="required_status_checks")] | length' "${ORG_PAYLOAD}")"
  if [ "${ORG_HAS_CHECKS}" != "0" ]; then
    warn "  * !! org-ruleset.json DOES declare required status checks:"
    jq -r '.rules[] | select(.type=="required_status_checks")
           | .parameters.required_status_checks[].context' "${ORG_PAYLOAD}" | sed 's/^/          required: /'
    warn "    Any repo above without a job of that exact name becomes UNMERGEABLE the moment"
    warn "    this is applied. Do not proceed unless you have verified every repo has them."
  fi
  printf '\n'

  # GitHub allows multiple rulesets with the same name — a plain POST every run would create
  # a duplicate instead of updating the one already in force. Look up an existing ruleset by
  # name first. A failed lookup is NOT "no existing ruleset": if we can't ask, we must not
  # guess, or we risk silently creating a diverging duplicate. Die instead.
  if ! ORG_LIST="$(gh api "orgs/${ORG}/rulesets" 2>&1)"; then
    die "cannot list existing rulesets for org ${ORG} (auth? network? rate limit?): ${ORG_LIST}
         Refusing to continue: without the existing list we cannot tell whether '${ORG_NAME}'
         already exists, and POSTing blind risks creating a duplicate ruleset that silently
         diverges from it. Fix the cause (gh auth status) and re-run."
  fi
  ORG_EXISTING_ID="$(printf '%s' "${ORG_LIST}" | jq -r --arg name "${ORG_NAME}" '[.[] | select(.name==$name)][0].id // empty')"

  if [ "${DRY}" -eq 1 ]; then
    if [ -n "${ORG_EXISTING_ID}" ]; then
      info "[dry-run] would PUT orgs/${ORG}/rulesets/${ORG_EXISTING_ID} (update existing '${ORG_NAME}') from ${ORG_SRC}"
    else
      info "[dry-run] would POST orgs/${ORG}/rulesets (create new '${ORG_NAME}') from ${ORG_SRC}"
    fi
    info "[dry-run] nothing was applied. Re-run without --dry-run (and with --yes) to apply."
    exit 0
  fi

  # ------------------------------------------------------------------------- confirmation
  # Not a formality. This is the one call in the repo that changes every repository in the
  # org at once, so it requires an affirmative act: --yes, or a typed 'y'. In a
  # non-interactive shell with no --yes, REFUSE — never assume consent from silence.
  if [ "${ASSUME_YES}" -ne 1 ]; then
    if [ ! -t 0 ]; then
      die "--org would apply '${ORG_NAME}' to all ${ORG_REPO_COUNT} repos listed above, and stdin
       is not a terminal so you cannot be asked. Re-run with --yes if that is what you want,
       or with --dry-run to see the plan without applying it."
    fi
    printf 'Apply "%s" to all %s repos in %s? [y/N] ' "${ORG_NAME}" "${ORG_REPO_COUNT}" "${ORG}"
    read -r reply
    case "${reply}" in
      y|Y|yes|YES) ;;
      *) info "aborted — nothing was applied."; exit 0 ;;
    esac
  fi

  if [ -n "${ORG_EXISTING_ID}" ]; then
    gh api -X PUT "orgs/${ORG}/rulesets/${ORG_EXISTING_ID}" --input "${ORG_PAYLOAD}" \
      || die "org ruleset update failed. Need the admin:org scope? gh auth refresh -h github.com -s admin:org"
    info "updated existing org ruleset '${ORG_NAME}' (id ${ORG_EXISTING_ID}) — every repo in ${ORG} now inherits it."
  else
    gh api -X POST "orgs/${ORG}/rulesets" --input "${ORG_PAYLOAD}" \
      || die "org ruleset failed. Need the admin:org scope? gh auth refresh -h github.com -s admin:org"
    info "created new org ruleset '${ORG_NAME}' — every repo in ${ORG} now inherits it."
  fi
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

NAME="$(jq -r '.name' "${PAYLOAD}")"

# GitHub allows multiple rulesets with the same name — a plain POST every run would create a
# duplicate instead of updating the one already in force. Look up an existing ruleset by name
# first. A failed lookup is NOT "no existing ruleset": if we can't ask, we must not guess, or
# we risk silently creating a diverging duplicate. Die instead.
if ! LIST="$(gh api "repos/${REPO}/rulesets" 2>&1)"; then
  die "cannot list existing rulesets for ${REPO} (auth? network? rate limit?): ${LIST}
       Refusing to continue: without the existing list we cannot tell whether '${NAME}'
       already exists, and POSTing blind risks creating a duplicate ruleset that silently
       diverges from it. Fix the cause (gh auth status) and re-run."
fi
EXISTING_ID="$(printf '%s' "${LIST}" | jq -r --arg name "${NAME}" '[.[] | select(.name==$name)][0].id // empty')"

if [ "${DRY}" -eq 1 ]; then
  if [ -n "${EXISTING_ID}" ]; then
    info "[dry-run] would PUT repos/${REPO}/rulesets/${EXISTING_ID} (update existing '${NAME}') with the required checks listed above"
  else
    info "[dry-run] would POST repos/${REPO}/rulesets (create new '${NAME}') with the required checks listed above"
  fi
  exit 0
fi

if [ -n "${EXISTING_ID}" ]; then
  gh api -X PUT "repos/${REPO}/rulesets/${EXISTING_ID}" --input "${PAYLOAD}" >/dev/null \
    || die "ruleset PUT failed for ${REPO} (id ${EXISTING_ID})"
  info "updated existing ruleset '${NAME}' (id ${EXISTING_ID}) on ${REPO} — main, staging, dev."
else
  gh api -X POST "repos/${REPO}/rulesets" --input "${PAYLOAD}" >/dev/null \
    || die "ruleset POST failed for ${REPO}"
  info "created new ruleset '${NAME}' on ${REPO} — main, staging, dev."
fi
info "Verify you can still merge:  gh api repos/${REPO}/branches/main/protection"
