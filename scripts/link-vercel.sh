#!/usr/bin/env bash
#
# Link this repo to a Vercel project. Linking only — this script NEVER deploys.
#
#   ./scripts/link-vercel.sh [--dry-run]
#
# ---------------------------------------------------------------------------------------------
# LINKING IS EASY. DEPLOYING IS A REVIEWED CODE CHANGE. That split is the whole design.
# ---------------------------------------------------------------------------------------------
#
# This script will:
#   * check you are logged into the Vercel CLI (it will NOT log you in — that is yours to do)
#   * REFUSE to link unless the repo's default branch is `main` (see why, below)
#   * run `vercel link` (interactive: you pick the scope and the project)
#   * establish that the production branch really is `main`, and REFUSE to finish if it is not:
#       - with VERCEL_TOKEN set, by asking the documented REST API (a real, machine-made check)
#       - without it, by making YOU read Branch Tracking in the dashboard and type what you see,
#         because the Vercel CLI genuinely cannot report it (no vercel command emits JSON)
#
# It will NOT:
#   * run `vercel deploy`, ever, under any flag
#   * enable any branch for deployment
#   * "fix" a wrong production branch behind your back
#   * claim to have verified something it did not. If it cannot check, it says so and makes a human
#     check — it never warns and carries on. (An earlier version did exactly that, and the check it
#     was "doing" could never have fired: it called `vercel project inspect --json`, a flag the CLI
#     does not have. template-tests/test_link_vercel.sh now contract-tests the CLI surface so an
#     invented flag fails the suite instead of silently disabling the control.)
#
# WHY THE PRODUCTION-BRANCH CHECK IS THE POINT OF THIS SCRIPT
#
# Vercel picks the production branch from `main`, `master`, or THE REPOSITORY'S DEFAULT BRANCH.
# There is NO documented API to set it — only an undocumented endpoint the dashboard calls.
# Vercel's own official workaround is "use the repository default branch".
#
# This template's default branch is `main` precisely so that Vercel's default is CORRECT. If the
# default branch is ever changed back to `dev`, then `dev` becomes the production branch, and
# EVERY MERGE TO dev DEPLOYS STRAIGHT TO PRODUCTION — bypassing staging, inverting the entire
# branch flow, silently. No error, no warning. That is the failure this check exists to catch.
#
# So we verify rather than assume, and a failure to verify is never treated as a verified pass.
#
# DEPLOYS ARE OFF UNTIL A HUMAN TURNS THEM ON
#
# vercel.json ships `"git": {"deploymentEnabled": false}`. Vercel treats every UNSPECIFIED branch
# as deployable, so `false` is the only posture that is safe by default. Enabling a branch means
# editing vercel.json — which means a PR, which means review and the branch flow. Runaway deploys
# are not prevented here by a warning nobody reads; they are prevented by the fact that turning a
# deploy on is a reviewed change to a tracked file.
#
set -euo pipefail

DRY=0
PROD_BRANCH="main"

warn() { printf '\033[33mWARN\033[0m  %s\n' "$*"; }
info() { printf '\033[32m--\033[0m    %s\n' "$*"; }
die()  { printf '\033[31mERROR\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    *)         die "unknown flag '$1' (usage: link-vercel.sh [--dry-run])" ;;
  esac
done

command -v vercel >/dev/null 2>&1 || die "the Vercel CLI is not installed. Install it: npm i -g vercel"
command -v gh     >/dev/null 2>&1 || die "gh is required but not installed. Install it: brew install gh"
command -v jq     >/dev/null 2>&1 || die "jq is required but not installed. Install it: brew install jq"

[ -f vercel.json ] || die "no vercel.json here. This script is for the 'next' stack — run it from
       the repo root of a repo initialised with: ./scripts/init-repo.sh next"

# ------------------------------------------------------------------ the deploys-off invariant
# Check this BEFORE linking. If vercel.json does not disable deployments, then linking the project
# is the moment deploys start firing — and by then it is too late to warn about it.
if ! grep -q '"deploymentEnabled": *false' vercel.json; then
  die "vercel.json does not carry \"deploymentEnabled\": false.

       REFUSING TO LINK. Vercel treats every UNSPECIFIED branch as deployable, so linking now
       would start deploying on the next push — including a production deploy. If you genuinely
       mean to enable deploys, do it as a reviewed PR that says so, and link afterwards."
fi
info "vercel.json disables deployments — linking will not start any deploys"

# ------------------------------------------------------------------------- the human gate
# vercel link is interactive (scope + project selection) and requires a real login. We refuse to
# run unattended: linking a repo to a deploy target is not something a CI job should do on its own.
if [ "${DRY}" -eq 0 ] && [ ! -t 0 ]; then
  die "stdin is not a terminal. This script is interactive by design — linking a repo to a deploy
       target is a human decision, not a pipeline step. Run it yourself in a terminal.
       To see what it would check without linking: $0 --dry-run"
fi

# We do NOT log you in. `vercel login` is an auth flow; a script that drives it is a script that
# handles your credentials, and this one has no business doing that.
if ! VERCEL_USER="$(vercel whoami 2>&1)"; then
  die "you are not logged into the Vercel CLI (or it cannot reach Vercel): ${VERCEL_USER}
       Log in yourself, then re-run:  vercel login"
fi
info "vercel user: ${VERCEL_USER}"

# ---------------------------------------------------------------- the default-branch invariant
# This is the check that keeps `dev` from becoming the production branch. Do it BEFORE linking, so
# a misconfigured repo never gets a Vercel project attached to it at all.
if ! DEFAULT_BRANCH="$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>&1)"; then
  die "cannot determine this repo's default branch (auth? network? no GitHub remote?): ${DEFAULT_BRANCH}
       Refusing to link: Vercel derives the PRODUCTION branch from the repository default branch,
       so if we cannot read it we cannot know what would deploy to production. A failure to verify
       is not a pass."
fi

if [ "${DEFAULT_BRANCH}" != "${PROD_BRANCH}" ]; then
  die "this repo's default branch is '${DEFAULT_BRANCH}', not '${PROD_BRANCH}'.

       REFUSING TO LINK. Vercel takes its production branch from the repository default branch.
       With '${DEFAULT_BRANCH}' as the default, every merge to '${DEFAULT_BRANCH}' would deploy
       straight to PRODUCTION — bypassing staging and inverting the branch flow, silently.

       Fix it, then re-run:
           gh repo edit --default-branch ${PROD_BRANCH}"
fi
info "default branch is '${DEFAULT_BRANCH}' — Vercel will take that as the production branch"

if [ "${DRY}" -eq 1 ]; then
  info "[dry-run] all pre-flight checks passed. Would now run: vercel link"
  info "[dry-run] nothing was linked, and nothing was deployed."
  exit 0
fi

# ----------------------------------------------------------------------------------- link
info "running 'vercel link' — pick the scope and project when prompted"
vercel link || die "vercel link failed or was cancelled — nothing was linked."

[ -f .vercel/project.json ] || die "vercel link reported success but .vercel/project.json is missing.
       Refusing to claim the repo is linked when it cannot be shown to be."
PROJECT_ID="$(jq -r '.projectId // empty' .vercel/project.json)"
[ -n "${PROJECT_ID}" ] || die "could not read projectId from .vercel/project.json"
info "linked to Vercel project ${PROJECT_ID}"

# --------------------------------------------------------- verify what Vercel ACTUALLY thinks
# A project may carry an explicit productionBranch override, set by hand in the dashboard, and
# that override WINS over the repository default branch we verified above. So the gh check alone
# is not sufficient — we have to ask Vercel.
#
# THE CLI CANNOT ANSWER THIS. `vercel project inspect` has NO --json flag (checked against CLI
# 54.7.1; no vercel command does), and its human-readable output is not a contract worth parsing.
# An earlier version of this script called `vercel project inspect --json`, which the real CLI
# rejects as an unknown option — so the check silently returned nothing, fell through to a
# warning, and LINKED ANYWAY. It was verification theatre: it could never have caught anything.
# Its tests passed only because the stub implemented a flag that does not exist.
#
# So there are exactly two honest paths, and neither of them is "warn and carry on":
#
#   VERCEL_TOKEN set -> ask the documented REST API (GET /v9/projects/{id}) and REFUSE on a
#                       wrong answer. This is a real check.
#   no token         -> we CANNOT verify. Say so, and make a HUMAN confirm they have looked,
#                       because "I could not check" is not "it is fine". That is this repo's
#                       first rule, and the old code broke it.
VERCEL_API="https://api.vercel.com"
ORG_ID="$(jq -r '.orgId // empty' .vercel/project.json)"

check_production_branch() { # echoes the branch, or "" if there is no override; returns 1 if it cannot ask
  local url resp
  url="${VERCEL_API}/v9/projects/${PROJECT_ID}"
  [ -n "${ORG_ID}" ] && url="${url}?teamId=${ORG_ID}"
  resp="$(curl --fail -sS -H "Authorization: Bearer ${VERCEL_TOKEN}" "${url}" 2>/dev/null)" || return 1
  printf '%s' "${resp}" | jq -e . >/dev/null 2>&1 || return 1     # not JSON -> we did not get an answer
  printf '%s' "${resp}" | jq -r '.link.productionBranch // empty'
}

if [ -n "${VERCEL_TOKEN:-}" ]; then
  if ACTUAL="$(check_production_branch)"; then
    if [ -z "${ACTUAL}" ]; then
      info "Vercel has no productionBranch override — it inherits the default branch ('${PROD_BRANCH}'). Verified."
    elif [ "${ACTUAL}" = "${PROD_BRANCH}" ]; then
      info "Vercel productionBranch is explicitly '${ACTUAL}'. Verified."
    else
      die "Vercel's production branch is '${ACTUAL}', not '${PROD_BRANCH}'.

       An explicit production-branch override is set in the Vercel dashboard, and it WINS over the
       repository default. Merges to '${ACTUAL}' would deploy to PRODUCTION.

       There is NO supported API to change this, so fix it by hand:
         Vercel dashboard -> Project -> Settings -> Environments -> Production -> Branch Tracking
       Set it to '${PROD_BRANCH}', then re-run this script to confirm."
    fi
  else
    die "VERCEL_TOKEN is set but the Vercel API would not answer (auth? network? rate limit?).

       Refusing to finish: a failure to verify is not a verified pass. Fix the cause, or unset
       VERCEL_TOKEN to take the manual-confirmation path instead."
  fi
else
  # No token: we genuinely cannot check. Do NOT print a green tick over an unknown, and do NOT
  # simply warn and exit 0 — a warning nobody actions is how an inert control ships. Make the
  # human look, and make them say so.
  printf '\n'
  warn "CANNOT VERIFY Vercel's production branch from here."
  warn "  The Vercel CLI cannot report it (no command emits JSON), and there is no VERCEL_TOKEN set."
  warn "  The repo default branch is '${PROD_BRANCH}', so Vercel SHOULD inherit it — but an explicit"
  warn "  override set in the dashboard WINS, and only you can see whether one exists."
  printf '\n'
  printf '  Open:  Vercel dashboard -> Project -> Settings -> Environments -> Production -> Branch Tracking\n'
  printf '  It must say: %s\n\n' "${PROD_BRANCH}"
  printf 'Type the production branch you see there (anything else aborts): '
  IFS= read -r seen || seen=""
  if [ "${seen}" != "${PROD_BRANCH}" ]; then
    die "you entered '${seen:-<nothing>}', not '${PROD_BRANCH}'.

       The repo is LINKED but its production branch is not confirmed. Do NOT enable any deploys
       until Branch Tracking says '${PROD_BRANCH}' — otherwise merges to '${seen:-that branch}'
       would go straight to production. Fix it in the dashboard and re-run this script.

       (Nothing is deploying: vercel.json still has deploymentEnabled: false.)"
  fi
  info "production branch confirmed as '${PROD_BRANCH}' by you (not machine-verified)"
fi

cat <<EOF

Linked. NOTHING IS DEPLOYING, and nothing will, until you say so.

vercel.json ships:   "git": { "deploymentEnabled": false }

To enable deploys, edit vercel.json and open a PR — that is the gate. Enabling a deploy is a
reviewed change to a tracked file, not a click. For this repo's branch flow that means:

    "git": {
      "deploymentEnabled": {
        "main": true,        # production
        "staging": true,     # pre-prod soak
        "dev": false         # integration branch — leave off unless you want a running preview
      }
    }

Anything you do NOT list defaults to TRUE in Vercel, so list every branch you care about.
EOF
