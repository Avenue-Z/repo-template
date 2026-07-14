#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=template-tests/lib.sh disable=SC1091
source template-tests/lib.sh

# ---------------------------------------------------------------------------------------
# DEPENDABOT IS BLIND TO templates/. THIS TEST IS WHAT KEEPS THEM FROM ROTTING.
#
# .github/dependabot.yml declares the github-actions ecosystem at `directory: "/"`, and for that
# ecosystem dependabot scans the ROOT .github/workflows ONLY. So it bumps the core workflows
# (guard-base-branch, secret-scan) and NEVER touches:
#
#     templates/python/.github/workflows/ci.yml
#     templates/node/.github/workflows/ci.yml
#     templates/next/.github/workflows/ci.yml
#
# Those files are not workflows *of this repo* — they are payload, copied into a generated repo by
# init-repo.sh, where they land at the root and dependabot finally sees them. Which means: a
# generated repo keeps its actions current, but THE TEMPLATE ITSELF ships whatever version it was
# born with, forever, silently. Every new repo starts life on a stale action.
#
# There is no dependabot config that fixes this (it will not scan a nested .github/workflows for
# the github-actions ecosystem). So the fix is a LOCKSTEP TEST, the same idiom this repo already
# uses to keep the gitleaks version in secret-scan.yml matched to the pre-commit hook:
#
#     any action used in BOTH the core and a template must be pinned to the SAME version.
#
# Dependabot bumps the core -> this suite goes red -> whoever merges the dependabot PR must bump
# the templates too. The rot becomes a failing test instead of a silent decay.

CORE_WF=(.github/workflows/*.yml)
TMPL_WF=(templates/*/.github/workflows/*.yml)

# action -> version, e.g. "actions/checkout v7"
pins() { grep -rhoE 'uses: *[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+@v?[0-9][^ ]*' "$@" \
           | sed -E 's/uses: *//' | sort -u; }

echo "action pins: the core and the templates must agree on every SHARED action"
core_pins="$(pins "${CORE_WF[@]}")"
tmpl_pins="$(pins "${TMPL_WF[@]}")"

if [ -z "$core_pins" ]; then fail "no action pins found in the core workflows — this test is not testing anything"; fi
if [ -z "$tmpl_pins" ]; then fail "no action pins found in the template workflows — this test is not testing anything"; fi

shared=0
while IFS= read -r cp; do
  action="${cp%@*}"; core_ver="${cp#*@}"
  # every version this action is pinned to across the templates
  tmpl_vers="$(grep -E "^${action}@" <<<"$tmpl_pins" | sed -E 's/.*@//' | sort -u || true)"
  [ -n "$tmpl_vers" ] || continue          # not used in the templates — nothing to keep in lockstep
  shared=$((shared + 1))
  bad=0
  while IFS= read -r tv; do
    [ "$tv" = "$core_ver" ] || { bad=1; fail "${action}: core is pinned to ${core_ver} but a template pins ${tv}. Dependabot bumped the core and cannot see templates/ — bump the template workflows to ${core_ver} too."; }
  done <<<"$tmpl_vers"
  [ "$bad" -eq 0 ] && pass "${action} is ${core_ver} in the core and in every template"
done <<<"$core_pins"

if [ "$shared" -eq 0 ]; then
  fail "no action is shared between the core and the templates — the lockstep check is vacuous. Did the workflows change shape?"
else
  pass "checked ${shared} action(s) shared between the core and the templates"
fi

# ---------------------------------------------------------------------------------------
# Every action must be pinned to an explicit major. `@main` / `@master` is a moving target: the
# action can change under you between two runs of the same commit, which is the opposite of what a
# required status check is for.
echo "action pins: nothing may float on a branch ref"
if float="$(grep -rhoE 'uses: *[^ ]+@(main|master|latest)' "${CORE_WF[@]}" "${TMPL_WF[@]}" || true)"; [ -n "$float" ]; then
  fail "an action floats on a branch ref (it can change under you between runs): ${float}"
else
  pass "every action is pinned to an explicit version, none float on main/master/latest"
fi

finish
