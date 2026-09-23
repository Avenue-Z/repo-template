#!/usr/bin/env bash
#
# Apply branch protection TO THIS REPO where the GitHub plan allows it, and say plainly where it
# does not.
#
#   ./scripts/apply-rulesets.sh [--dry-run]
#
# Branch protection and rulesets are UNAVAILABLE on private repos on the Free plan — for
# everyone, including org owners. This script never pretends otherwise: if it cannot protect a
# branch, it says so and exits 0.
#
# THIS SCRIPT ONLY EVER TOUCHES ONE REPO: the one you are standing in.
#
# The org-wide apply used to live here behind `--org`. It does not any more. It is
# scripts/apply-org-ruleset.sh, a separate script, precisely BECAUSE it sat one flag away from
# this routine command — a fat-finger, a stray tab-complete, or an Up-arrow through shell history
# was all that separated "protect my new repo" from "rewrite protection on all ~64 repos in the
# org". Nothing you can type here reaches that code.
#
set -euo pipefail

ORG="Avenue-Z"
DRY=0

warn() { printf '\033[33mWARN\033[0m  %s\n' "$*" >&2; }
info() { printf '\033[32m--\033[0m    %s\n' "$*"; }
die()  { printf '\033[31mERROR\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    # Name the removed flags explicitly. Someone typing them is working from memory or an old
    # runbook; "unknown flag" would leave them hunting for a typo instead of telling them the
    # org-wide apply deliberately moved out of reach.
    --org)     die "--org is gone from this script, by design. The org-wide apply is now its own
       command, so that it cannot be reached by a flag on the one you run routinely:

           ./scripts/apply-org-ruleset.sh --dry-run

       It applies to EVERY repo in ${ORG} and will make you type a challenge phrase." ;;
    --yes|-y)  die "there is no --yes on this script — it has nothing destructive to confirm.
       (If you are reaching for it out of habit: the org-wide apply moved to
       scripts/apply-org-ruleset.sh, and that one has no --yes either, on purpose.)" ;;
    *)         die "unknown flag '$1' (usage: apply-rulesets.sh [--dry-run])" ;;
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
if [ -z "${PLAN}" ] || [ "${PLAN}" = "null" ]; then
  die "the ${ORG} plan came back empty — the token likely cannot read org details.
       Refusing to continue rather than assume you are not on Free.
       Try: gh auth refresh -h github.com -s read:org"
fi
info "org plan: ${PLAN}"

# ----------------------------------------------------------------- repo ruleset
# Compute which status checks would be required. This is a purely local decision — it only
# depends on whether ci.yml exists in this working copy — so it is computed and shown up
# front, regardless of whether we can even reach GitHub to find out what repo we're in.
#
# Add 'ci' to the required checks ONLY if ci.yml is actually present. A required check
# that never reports does not fail the PR — it hangs PENDING forever, and nothing merges.
PAYLOAD="$(mktemp)"; trap 'rm -f "${PAYLOAD}"' EXIT
cp .github/rulesets/repo-ruleset.json "${PAYLOAD}"

# Add a context to the required checks ONLY if the workflow that reports it actually exists here.
# A required check that never reports does not fail a PR — it hangs it PENDING FOREVER, and
# nothing in the repo can be merged again. So both of these are conditional on a file, not on an
# assumption about which repo we are in.
#
#   ci             -> arrives with the stack, in a GENERATED repo (init-repo.sh copies it).
#   template-tests -> exists ONLY in repo-template itself. init-repo.sh DELETES it, so a generated
#                     repo must never require it. This is why the check is file-gated rather than
#                     baked into repo-ruleset.json, which both kinds of repo share.
add_context() { # <context> <workflow-file> <why-it-matters>
  if [ -f "$2" ]; then
    info "$2 present — adding '$1' to required checks"
    jq --arg c "$1" '(.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks)
        += [{"context":$c}]' "${PAYLOAD}" > "${PAYLOAD}.tmp" && mv "${PAYLOAD}.tmp" "${PAYLOAD}"
  else
    info "no $2 — not requiring '$1' ($3)"
  fi
}
# The `checks` context is NOT baked into repo-ruleset.json, because that file is shared across
# every shape checks.yml can take, and they do not all report the same context name. There are
# THREE shapes, not two:
#
#   1. repo-template itself -> checks.yml IS the reusable workflow (`workflow_call:`). Its
#      pull_request runs are ordinary top-level jobs, so the context is literally `checks`.
#   2. a generated repo, normally -> checks.yml is a CALLER: the `checks` job's only key is
#      `uses:`. A called job's context is `<caller-job> / <called-job>`, so this reports
#      `checks / checks`.
#   3. a self-contained copy -> no `workflow_call:`, and the `checks` job has no `uses:` either
#      (it has its own `runs-on:`/`steps:`, same as shape 1). This is the documented migration
#      ROLLBACK path — every one of the ~11 fleet repos holds exactly this shape today — and it
#      reports plain `checks`, the same as shape 1.
#
# Keying the second branch on the ABSENCE of `workflow_call` (rather than the PRESENCE of `uses:`)
# used to fold shape 3 into shape 2 and require `checks / checks` on a checks.yml that actually
# reports `checks` — on a repo with live rulesets that hangs every PR PENDING FOREVER. Requiring
# the wrong context never fails a PR outright; it just never reports and nothing merges again.
# `workflow_call` and the job's own `uses:` are the discriminators, not a guess, because
# template-tests/test_reusable_contract.sh asserts the former is present in repo-template and
# template-tests/test_apply_rulesets.sh exercises all three shapes directly.
job_has_uses() { # <workflow-file> -- true if the 'checks' job's own key is 'uses:' (shape 2)
  awk '
    /^  checks:$/ { injob=1; next }
    injob && /^  [^ ]/ { injob=0 }
    injob && /^    uses:/ { found=1 }
    END { exit !found }
  ' "$1"
}
# A CALLER THAT DOES NOT GRANT id-token: write MUST NOT BE GIVEN A REQUIRED CONTEXT. checks.yml
# requests that permission (it reads the ref it was called at from the OIDC job_workflow_ref claim),
# so a caller that does not grant it is asking for an ELEVATION. That does not fail the job: the run
# is a `startup_failure` with ZERO jobs, `checks / checks` never reports, and requiring it hangs every
# PR PENDING FOREVER (measured: avenue-z-ci-lab/adopter-private run 34709355618). init-repo.sh writes
# the grant for new repos; this catches a caller written by hand during migration.
#
# What counts is the caller job's EFFECTIVE grant — `checks` in checks.yml, the python-ci caller in
# ci.yml: its own `permissions` block REPLACES the
# workflow-level one, which applies only when the job has none. Comments are skipped, so prose that
# mentions the grant cannot satisfy this. Like job_has_uses it reads block-style YAML at 2-space
# indent, which is what init-repo.sh writes; any other spelling (flow style, write-all, quoting) is
# refused — a loud local error, never a false pass.
job_grants_id_token() { # <workflow-file> <job>
  awk -v job="$2" '
    /^[ ]*#/ || /^[ ]*$/ { next }
    /^permissions:/ { wf=1; next }
    wf && /^[^ ]/ { wf=0 }
    wf && /^  id-token:[ ]*write[ ]*(#.*)?$/ { wfgrant=1 }
    $0 == "  " job ":" { injob=1; next }
    injob && (/^[^ ]/ || /^  [^ ]/) { injob=0; jp=0 }
    injob && /^    permissions:/ { jobblock=1; jp=1; next }
    jp && /^    [^ ]/ { jp=0 }
    jp && /^      id-token:[ ]*write[ ]*(#.*)?$/ { jobgrant=1 }
    END { exit !(jobblock ? jobgrant : wfgrant) }
  ' "$1"
}
if [ ! -f .github/workflows/checks.yml ]; then
  info "no .github/workflows/checks.yml — not requiring any 'checks' context"
elif grep -qE '^ *workflow_call:' .github/workflows/checks.yml; then
  add_context 'checks'          .github/workflows/checks.yml "this checks.yml IS the reusable workflow"
elif job_has_uses .github/workflows/checks.yml; then
  job_grants_id_token .github/workflows/checks.yml checks || die ".github/workflows/checks.yml is a caller, but its 'checks' job is not granted id-token: write.
       Refusing to require 'checks / checks'. The reusable checks.yml requests that permission, and a
       caller that does not grant it gets a startup_failure with ZERO jobs: the context never reports,
       so every PR would hang PENDING FOREVER. Add this to the 'checks' job (a job-level block
       REPLACES the workflow-level one, so contents: read has to be restated) and re-run:

           permissions:
             contents: read
             id-token: write"
  add_context 'checks / checks' .github/workflows/checks.yml "this checks.yml is a caller; a called job reports '<caller>/<called>'"
else
  add_context 'checks'          .github/workflows/checks.yml "this checks.yml is a self-contained copy (the migration rollback path); it reports 'checks' directly"
fi
# A ci.yml that CALLS python-ci.yml is held to the same rule as a checks.yml caller: python-ci.yml
# requests id-token: write, and a caller job that does not grant it is a startup_failure, so `ci`
# never reports and requiring it hangs every PR PENDING FOREVER.
#
# EVERY call site is checked, and each must sit under a job header this script can READ — a bare
# `  <job>:` with `uses:` at 4 spaces, which is what init-repo.sh writes. Anything else prints `?` and
# is refused. Crediting the call to "the last header that did parse" is the false pass: a trailing
# comment on the caller's header hands the check to the job above it, and if THAT job holds the grant,
# `ci` is required on a caller that will startup_failure. `?` and not an empty line, because `$(...)`
# strips trailing newlines and an empty last entry would silently vanish.
#
# The pattern has no `@`: a same-repo call (`uses: ./.github/workflows/python-ci.yml`) carries no ref
# and still needs the grant, because python-ci.yml only skips the OIDC lookup inside repo-template.
# That means repo-template's OWN self-call, if it ever gets a ci.yml, is refused too. Grant id-token:
# write on that job anyway: it is harmless there, and it is one line against a special case here.
#
# THE GRANT IS NOT ENOUGH. 'ci' is the required context, so a job named `ci` has to exist, and it has
# to `needs:` every caller. Without the job, nothing reports 'ci' and every PR hangs PENDING FOREVER.
# Without the needs, `ci` goes green while python-ci is red and the PR merges: a FALSE GREEN.
#
# ci_job_needs prints the `ci` job's needs, one per line, from the three block-style spellings:
# `needs: x`, `needs: [x, y]` and a `- x` list (dashes at 6 spaces or at the key's own 4).
# Exit 2: no `ci` job under `jobs:`. Exit 5: the job is itself a caller (`uses:`) of ANY reusable
# workflow, so it reports as 'ci / <called-job>'. Exit 4: the job reports under another context,
# because of a `name:` other than ci, or a `strategy:` (matrix legs report as 'ci (1)', 'ci (2)').
# Exit 3: a needs spelling it cannot read (a flow list over several lines, say), refused rather than
# read as "needs nothing" or "needs everything". Exit 6: the job can be SKIPPED — it has `needs:` but no
# `if: always()`, or it has any other `if:`. A skipped required check PASSES: the PR is mergeable
# (measured, docs/notes/2026-09-23-phase-g-lab-proof-2.md, Part A), so a skippable `ci` is a FALSE
# GREEN on every PR whose tests fail. A `ci` with no needs and no `if:` (node, next) cannot be skipped.
# An `if` it cannot read is counted as skippable, never as absent: a quoted key (`"if":`), `if :`, a
# `<<:` merge key (it can bring an `if:` in), or a job body not at 4-space indent. Exit 7: the job
# has `needs:` but never reads their results (`toJSON(needs)` or `needs.<job>.result`), so it runs
# under `if: always()` and goes green while a needed job is red: the same FALSE GREEN.
# 5, 4, 6 and 7 are checked before 3 because 3 is only fatal for a python-ci caller. 5 is its own
# flag, not a value of `shape`, so a later `strategy:` cannot overwrite it and blame the wrong line.
ci_job_needs() { # <workflow-file>
  awk '
    /^[ ]*#/ || /^[ ]*$/ { next }
    /^[^ ]/ { injobs = ($0 ~ /^jobs:[ ]*(#.*)?$/); inci = 0; next }
    injobs && /^  [^ ]/ { inci = ($0 ~ /^  ci:[ ]*(#.*)?$/); if (inci) found = 1; inlist = 0; body = 0; next }
    !inci { next }
    !body { body = 1; if ($0 !~ /^    [^ ]/) skippable = 1 }
    /^    (["\047]if["\047]|if[ ]+)[ ]*:/ || /^    <<[ ]*:/ { skippable = 1 }
    /toJSON[(][ ]*needs[ ]*[)]|needs[.][A-Za-z0-9_*-]+[.]result/ { verdict = 1 }
    inlist && /^(      |    )- / { v = $0; sub(/^ *- [ ]*/, "", v); sub(/[ ]*(#.*)?$/, "", v); print v; next }
    inlist { inlist = 0 }
    /^    name:/ && $0 !~ /^    name:[ ]*("ci"|\047ci\047|ci)[ ]*(#.*)?$/ { shape = 1 }
    /^    strategy:/ { shape = 1 }
    /^    uses:/ { calls = 1 }
    /^    if:/ { if ($0 ~ /^    if:[ ]*("|\047)?(always[(][)]|[$][{][{][ ]*always[(][)][ ]*[}][}])("|\047)?[ ]*(#.*)?$/) always = 1; else skippable = 1 }
    /^    needs:/ {
      hasneeds = 1
      v = $0; sub(/^    needs:[ ]*/, "", v); sub(/[ ]*(#.*)?$/, "", v)
      if (v == "") inlist = 1
      else if (v ~ /^[A-Za-z0-9_-]+$/) print v
      else if (v ~ /^\[[^]]*\]$/) {
        n = split(substr(v, 2, length(v) - 2), a, ",")
        for (i = 1; i <= n; i++) { gsub(/^[ ]+|[ ]+$/, "", a[i]); if (a[i] != "") print a[i] }
      }
      else bad = 1
    }
    END { if (!found) exit 2; if (calls) exit 5; if (shape) exit 4; if (skippable || (hasneeds && !always)) exit 6; if (hasneeds && !verdict) exit 7; if (bad) exit 3 }
  ' "$1"
}
if [ -f .github/workflows/ci.yml ]; then
  ci_needs_rc=0
  ci_needs="$(ci_job_needs .github/workflows/ci.yml)" || ci_needs_rc=$?
  [ "${ci_needs_rc}" -ne 2 ] || die ".github/workflows/ci.yml has no job named 'ci' (a '  ci:' header under 'jobs:').
       Refusing to require the 'ci' context: nothing would ever report it, and every PR would hang
       PENDING FOREVER."
  [ "${ci_needs_rc}" -ne 5 ] || die ".github/workflows/ci.yml has a 'ci' job that is itself a caller of a reusable workflow ('uses:').
       Refusing to require 'ci': a called job reports as 'ci / <called-job>', so nothing reports plain
       'ci' and every PR would hang PENDING FOREVER. Move the call to its own job and add that job to
       the 'ci' job's needs, the way init-repo.sh does for python-ci."
  [ "${ci_needs_rc}" -ne 4 ] || die ".github/workflows/ci.yml has a 'ci' job with a name: override or a strategy: (matrix) block,
       so it reports under another context name ('<name>', or 'ci (<leg>)'). Refusing to require 'ci':
       nothing would report it, and every PR would hang PENDING FOREVER. Remove the name: (or set it
       to ci) and move any matrix into a job that 'ci' needs."
  [ "${ci_needs_rc}" -ne 6 ] || die ".github/workflows/ci.yml has a 'ci' job that can be SKIPPED: it has needs: but no 'if: always()',
       some other if:, or an if (or job body) this script cannot read. A skipped required check PASSES —
       the PR is mergeable — so every PR whose tests fail would merge green. Refusing to require 'ci'.
       Give the 'ci' job exactly 'if: always()', written as a plain 'if:' key at 4-space indent, and
       let its verdict step fail when a needed job did not succeed, the way init-repo.sh does."
  [ "${ci_needs_rc}" -ne 7 ] || die ".github/workflows/ci.yml has a 'ci' job with needs: that never reads their results
       (toJSON(needs) or needs.<job>.result). Under 'if: always()' it runs and goes green while a needed
       job is red, so every PR whose tests fail would merge green. Refusing to require 'ci'. Add a
       verdict step that fails unless every needed job is 'success', the way init-repo.sh does."
  py_callers="$(awk '
    /^[ ]*#/ || /^[ ]*$/ { next }
    /^  [^ ]/ { j = ($0 ~ /^  [A-Za-z0-9_-]+:$/) ? substr($1, 1, length($1)-1) : "?" }
    /^[^#]*uses:.*\/python-ci\.yml/ { print ((/^    uses:/ && j != "") ? j : "?") }
  ' .github/workflows/ci.yml)"
  if [ -n "${py_callers}" ]; then
    [ "${ci_needs_rc}" -eq 0 ] || die ".github/workflows/ci.yml calls python-ci.yml, but this script cannot read the 'ci' job's needs.
       It reads 'needs: x', 'needs: [x, y]' on one line, or a '- x' list at 6-space indent. Refusing to
       require 'ci' rather than guess whether it sees the python-ci result: if it does not, python-ci
       goes red, 'ci' goes green, and the PR merges. Write it the way init-repo.sh does and re-run."
    while IFS= read -r py_caller; do
      [ "${py_caller}" != "?" ] || die ".github/workflows/ci.yml calls python-ci.yml, but not from a job this script can read
       (a bare '  <job>:' header at 2-space indent, with 'uses:' at 4). Refusing to require 'ci' rather
       than guess which job has to grant id-token: write — a wrong guess hangs every PR PENDING FOREVER.
       Write the caller the way init-repo.sh does and re-run."
      grep -qxF -- "${py_caller}" <<<"${ci_needs}" || die ".github/workflows/ci.yml calls python-ci.yml from job '${py_caller}', but the 'ci' job does not need it
       (needs as read: $(tr '\n' ' ' <<<"${ci_needs:-<none>}")). Refusing to require 'ci': it would go green
       while '${py_caller}' is red, and the PR would merge. Add '${py_caller}' to the 'ci' job's needs and re-run."
      job_grants_id_token .github/workflows/ci.yml "${py_caller}" || die ".github/workflows/ci.yml calls python-ci.yml from job '${py_caller}', which is not granted id-token: write.
       Refusing to require 'ci'. Without the grant the run is a startup_failure with ZERO jobs, so
       'ci' never reports and every PR would hang PENDING FOREVER. Add this to the '${py_caller}' job
       (a job-level block REPLACES the workflow-level one) and re-run:

           permissions:
             contents: read
             id-token: write"
    done <<<"${py_callers}"
  fi
fi
add_context ci             .github/workflows/ci.yml             "a required check with no workflow hangs every PR pending forever"
add_context template-tests .github/workflows/template-tests.yml "this workflow is the template's own, and init-repo.sh removes it"
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
  warn "  Enforcement in this repo is: the 'checks' workflow on PRs, and convention."
  warn "  To get real protection: make this repo public, or upgrade ${ORG} to GitHub Team."
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
