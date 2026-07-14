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
#   * run `vercel link` (interactive: you pick the scope and the project)
#   * VERIFY the production branch is `main`, and REFUSE to finish if it is not
#
# It will NOT:
#   * run `vercel deploy`, ever, under any flag
#   * enable any branch for deployment
#   * "fix" a wrong production branch behind your back
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
# Do not trust the default we just reasoned about — ask Vercel. A project may carry an explicit
# productionBranch override set by hand in the dashboard, and that override wins.
#
#   null / absent  -> Vercel inherits the repository default branch, which we verified is main. OK.
#   "main"         -> explicit and correct. OK.
#   anything else  -> an override that would deploy the WRONG branch to production. Refuse.
if PROJECT_JSON="$(vercel project inspect "${PROJECT_ID}" --json 2>/dev/null)" \
     && [ -n "${PROJECT_JSON}" ]; then
  ACTUAL="$(printf '%s' "${PROJECT_JSON}" | jq -r '.link.productionBranch // empty' 2>/dev/null || true)"
  if [ -z "${ACTUAL}" ]; then
    info "Vercel has no productionBranch override — it inherits the default branch ('${PROD_BRANCH}'). Correct."
  elif [ "${ACTUAL}" = "${PROD_BRANCH}" ]; then
    info "Vercel productionBranch is explicitly '${ACTUAL}'. Correct."
  else
    die "Vercel's production branch is '${ACTUAL}', not '${PROD_BRANCH}'.

       Someone has set an explicit production-branch override in the Vercel dashboard, and it
       WINS over the repository default. Merges to '${ACTUAL}' would deploy to production.

       There is NO supported API to change this, so you must fix it by hand:
         Vercel dashboard -> Project -> Settings -> Environments -> Production -> Branch Tracking
       Set it to '${PROD_BRANCH}', then re-run this script to confirm."
  fi
else
  # Could not ask. Say so plainly — do not print a green tick over an unknown.
  warn ""
  warn "COULD NOT VERIFY Vercel's production branch (the CLI would not report it)."
  warn "  The repo default branch is '${PROD_BRANCH}', so Vercel SHOULD inherit it — but an"
  warn "  explicit override set in the dashboard would win, and we could not check for one."
  warn "  Confirm by hand before enabling any deploys:"
  warn "    Vercel dashboard -> Project -> Settings -> Environments -> Production -> Branch Tracking"
  warn ""
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
