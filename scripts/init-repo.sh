#!/usr/bin/env bash
#
# Turn a fresh copy of Avenue-Z/repo-template into a working repo.
#
#   ./scripts/init-repo.sh <python|node> [--team <slug>] [--no-push]
#
# --team <slug>: writes .github/CODEOWNERS naming @Avenue-Z/<slug>, after verifying the
#   team exists. If the team exists but lacks write access to the repo, the script GRANTS
#   it push (write) access rather than just warning — GitHub silently ignores a CODEOWNERS
#   entry for a team without write, so a warning nobody actions leaves the file inert.
#   Granting requires repo-admin or org-owner rights; if that fails the script dies rather
#   than write a CODEOWNERS that GitHub will ignore.
#
set -euo pipefail

ORG="Avenue-Z"
STACK=""
TEAM=""
PUSH=1

warn() { printf '\033[33mWARN\033[0m  %s\n' "$*" >&2; }
info() { printf '\033[32m--\033[0m    %s\n' "$*"; }
die()  { printf '\033[31mERROR\033[0m %s\n' "$*" >&2
         printf 'Recover with: git checkout -- . && git clean -fd\n' >&2
         exit 1; }

[ $# -ge 1 ] || die "usage: init-repo.sh <python|node> [--team <slug>] [--no-push]"
STACK="$1"; shift
case "${STACK}" in python|node) ;; *) die "stack must be 'python' or 'node', got '${STACK}'" ;; esac
while [ $# -gt 0 ]; do
  case "$1" in
    # An empty value is not the only bad value: `--team --no-push` would silently set
    # TEAM='--no-push' and then go looking for a team by that name. Anything starting
    # with '-' is a flag the user forgot to give a value to, not a slug.
    --team)    TEAM="${2:-}"
               [ -n "${TEAM}" ] || die "--team needs a slug"
               case "${TEAM}" in -*) die "--team needs a slug, got the flag '${TEAM}'" ;; esac
               shift 2 ;;
    --no-push) PUSH=0; shift ;;
    *)         die "unknown flag '$1'" ;;
  esac
done

git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository"

# HEAD MUST be dev. GitHub's "Use this template" gives you a single branch — main — so
# without this check the init commit lands on main, `dev` is never created, and the push
# dies with "src refspec dev does not match any" AFTER the commit. Worse, if dev exists
# but is not HEAD, dev is left stale — still carrying templates/ — and dev is the branch
# developers actually work on. Assert before we mutate anything.
HEAD_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
[ "${HEAD_BRANCH}" = dev ] || die "HEAD is '${HEAD_BRANCH:-detached}', not 'dev'. This script cuts staging and main from dev.
       Run: git checkout -b dev   (or: git checkout dev)   then re-run."

# NOTE: every function is defined BEFORE it is called. Bash executes a script
# sequentially — a call placed above its definition dies with "command not found".
# The idempotency short-circuit calls ensure_branches, so it lives at the bottom.

# ------------------------------------------------------------------ CODEOWNERS
# GitHub SILENTLY IGNORES a CODEOWNERS entry whose team does not exist or lacks
# write access. So we verify — granting write when it's missing — or we ship no
# file at all. Never enforcement theater.
#
# The guard below distinguishes "team is absent" (404 — an answer) from "I could not
# tell" (auth, network, rate limit — NOT an answer). set -e is disabled inside an
# `if` condition, so a bare `if ! gh api` would treat an expired token as a missing
# team and silently drop the control. That is the exact failure this file prevents.
resolve_codeowners() {
  if [ -z "${TEAM}" ]; then
    warn "no --team given — this repo will have NO code-owner review."
    rm -f .github/CODEOWNERS.tmpl
    return 0
  fi

  local out
  if out=$(gh api "orgs/${ORG}/teams/${TEAM}" 2>&1); then
    :   # exists
  elif grep -qE '"status": *"404"|HTTP 404|Not Found' <<<"${out}"; then
    warn "team '${TEAM}' does not exist in ${ORG} — dropping CODEOWNERS (no code-owner review)."
    rm -f .github/CODEOWNERS.tmpl
    return 0
  else
    die "cannot verify team '${TEAM}' (not a 404 — auth? network? rate limit?): ${out}"
  fi

  # Existence is necessary but NOT sufficient: the team must also hold write access
  # on THIS repo, or the CODEOWNERS entry is silently ignored just the same.
  #
  # The Accept header is REQUIRED. Without it this endpoint answers 204 No Content with an
  # EMPTY BODY, so `-q .permissions.push` yields "" — never "true" — and the check warns
  # "no WRITE access" for every team on earth, including the ones that have it. The
  # documented media type below returns a real JSON body: {"permissions":{"push":true,...},
  # "role_name":"write",...}. A check that cannot say yes is not a check.
  local repo perm
  repo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo '')"
  if [ -n "${repo}" ]; then
    if perm=$(gh api -H "Accept: application/vnd.github.v3.repository+json" \
                "orgs/${ORG}/teams/${TEAM}/repos/${repo}" -q '.permissions.push' 2>&1); then
      :   # got a real answer, true or false
    elif grep -qE '"status": *"404"|HTTP 404|Not Found' <<<"${perm}"; then
      # A 404 here is an ANSWER: the team is not attached to the repo at all — fold that
      # into "false" so the grant below fires for it exactly like an explicit non-write.
      perm=false
    else
      # Anything else (auth, network, rate limit) is NOT an answer. Do not guess.
      die "cannot check team write access (not a 404 — auth? network? rate limit?): ${perm}"
    fi

    if [ "${perm}" != "true" ]; then
      # A warning nobody actions leaves an inert CODEOWNERS — the exact silent-enforcement-
      # theater failure this file exists to prevent. Grant write instead of just naming the
      # problem. One PUT both attaches the team to the repo (if it wasn't) and sets push,
      # so it covers "not attached at all" and "attached with a lesser permission" alike.
      local grant
      if grant=$(gh api -X PUT "orgs/${ORG}/teams/${TEAM}/repos/${repo}" -f permission=push 2>&1); then
        info "granted @${ORG}/${TEAM} write access to ${repo}"
      elif grep -qE '"status": *"403"|HTTP 403|Forbidden' <<<"${grant}"; then
        die "cannot grant @${ORG}/${TEAM} write access to ${repo} (403 Forbidden) — you need repo-admin or org-owner rights on ${repo}. CODEOWNERS will be inert until someone with those rights grants the team write."
      else
        die "failed to grant @${ORG}/${TEAM} write access to ${repo} (not a 403 — auth? network? rate limit?): ${grant}"
      fi

      # Do not assume the PUT worked because it returned 0 — re-verify before writing
      # CODEOWNERS. If it still isn't true, die rather than ship an inert file.
      if perm=$(gh api -H "Accept: application/vnd.github.v3.repository+json" \
                  "orgs/${ORG}/teams/${TEAM}/repos/${repo}" -q '.permissions.push' 2>&1); then
        [ "${perm}" = "true" ] || die "granted write to @${ORG}/${TEAM} on ${repo} but re-verification still shows push=${perm:-unknown} — refusing to write CODEOWNERS"
      else
        die "cannot re-verify team write access after granting (not a 404 — auth? network? rate limit?): ${perm}"
      fi
    fi
  fi

  # Write the LIVE file — without the template's "TEMPLATE — not live" preamble, which
  # would otherwise sit as the first line of the file that IS live, contradicting itself.
  {
    printf '# Code owners. Written by scripts/init-repo.sh after verifying that\n'
    printf '# @%s/%s exists in the org.\n' "${ORG}" "${TEAM}"
    sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' \
        -e "s|@${ORG}/TEAM_SLUG|@${ORG}/${TEAM}|" .github/CODEOWNERS.tmpl
  } > .github/CODEOWNERS
  rm -f .github/CODEOWNERS.tmpl
  info "wrote .github/CODEOWNERS for @${ORG}/${TEAM}"
}

# -------------------------------------------------------------- branch lineage
# Cut staging and main from the POST-cleanup dev. Before the cleanup commit, dev
# still holds templates/ — branching early would leave all three heads carrying
# dead files forever. Create-if-absent; never force-push.
ensure_branches() {
  local head; head="$(git rev-parse --abbrev-ref HEAD)"
  for b in staging main; do
    if git rev-parse --verify -q "${b}" >/dev/null; then
      info "branch ${b} already exists — leaving it alone (re-run repairs absence, not drift)"
    else
      git branch "${b}" "${head}"
      info "created ${b} from ${head}"
    fi
  done
  if [ "${PUSH}" -eq 1 ]; then
    # Push only what exists. Naming a branch that isn't there aborts the whole push with
    # "src refspec X does not match any" — and pushes nothing at all, including the
    # branches that WERE fine.
    local existing=()
    for b in dev staging main; do
      if git rev-parse --verify -q "${b}" >/dev/null; then existing+=("${b}"); fi
    done
    [ "${#existing[@]}" -gt 0 ] || die "no dev/staging/main branch exists to push"
    git push -u origin "${existing[@]}"
    info "pushed ${existing[*]}"
  else
    info "--no-push: branches created locally only"
  fi
}

# ------------------------------------------------------------------------ main

# Idempotency short-circuit. Placed HERE, after ensure_branches is defined.
# Re-run repairs ABSENCE, not DRIFT: if templates/ is gone, the stack was selected on a
# previous run — do not re-copy, do not reset, do not force-push. A stale main is
# reconciled by opening a PR, not by re-running this script.
if [ ! -d templates ]; then
  info "templates/ already removed — this repo is initialized. Ensuring branches exist."
  ensure_branches
  exit 0
fi

info "initializing as a '${STACK}' repo"

[ -d "templates/${STACK}" ] || die "templates/${STACK} not found"

# 1. copy, 2. verify, 3. remove, 4. commit once, 5. push dev, 6. THEN branch.
cp -R "templates/${STACK}/." .
if [ "${STACK}" = python ]; then
  [ -f pyproject.toml ] || die "copy failed: pyproject.toml missing"
else
  [ -f package.json ] || die "copy failed: package.json missing"
fi
[ -f .github/workflows/ci.yml ] || die "copy failed: .github/workflows/ci.yml missing"
info "copied templates/${STACK} and verified"

resolve_codeowners

# Dependabot: the core declares only github-actions (the one ecosystem it actually has).
# Append the block for the stack we just selected, so this repo declares exactly what it has.
add_dependabot_ecosystem() {
  local eco
  case "${STACK}" in python) eco=pip ;; node) eco=npm ;; esac
  cat >> .github/dependabot.yml <<EOF
  - package-ecosystem: ${eco}
    directory: "/"
    schedule: { interval: weekly }
    target-branch: dev
    open-pull-requests-limit: 5
EOF
  info "added the '${eco}' ecosystem to .github/dependabot.yml"
}
add_dependabot_ecosystem

# Strip everything that is ABOUT the template rather than part of the generated repo. The
# spec promises a generated repo carries ZERO dead files.
#
#   templates/       — the unselected stack (and the selected one, now copied into place)
#   template-tests/  — the template's OWN bash suite. It must NOT ship: it tests the
#                      template's premises, two of which INVERT the moment ci.yml exists
#                      (test_rulesets.sh / test_apply_rulesets.sh assert "the core has no
#                      ci.yml"), so a generated repo would ship two tests that FAIL out of
#                      the box. It lives in template-tests/ — not tests/ — precisely so this
#                      one `rm -rf` removes it wholesale without touching the stack's own
#                      tests/ skeleton, which we just copied in.
#   the template's own spec/plan — 500 lines about repo-template itself, meaningless in a
#                      generated repo. The empty docs/superpowers/{specs,plans}/ dirs and
#                      their README + .gitkeep stay: that is where the new repo's OWN
#                      specs and plans go.
#
# init-repo.sh does NOT delete itself: criterion 7 requires a re-run to be a no-op exiting 0,
# and a self-deleting script cannot be re-run. The re-run IS the recovery path for a first run
# that died partway. scripts/ keeps apply-rulesets.sh regardless.
rm -rf templates template-tests
info "removed templates/ and template-tests/ (the template's own self-tests)"

rm -f docs/superpowers/specs/2026-07-13-avenue-z-repo-template-design.md \
      docs/superpowers/plans/2026-07-13-avenue-z-repo-template.md
info "removed the template's own spec and plan"

git add -A
git commit -q -m "chore: initialize ${STACK} repo from Avenue-Z/repo-template"
info "committed the initialized tree"

if [ "${PUSH}" -eq 1 ]; then
  git push -u origin "$(git rev-parse --abbrev-ref HEAD)"
fi
ensure_branches

cat <<EOF

Done. Next:
  1. pre-commit install
  2. Fill in the TODOs in README.md and CLAUDE.md
  3. ./scripts/apply-rulesets.sh          # adds 'ci' to required checks now that ci.yml exists
EOF
