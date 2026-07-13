#!/usr/bin/env bash
#
# Turn a fresh copy of Avenue-Z/repo-template into a working repo.
#
#   ./scripts/init-repo.sh <python|node> [--team <slug>] [--no-push]
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
    --team)    TEAM="${2:-}"; [ -n "${TEAM}" ] || die "--team needs a slug"; shift 2 ;;
    --no-push) PUSH=0; shift ;;
    *)         die "unknown flag '$1'" ;;
  esac
done

git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository"

# NOTE: every function is defined BEFORE it is called. Bash executes a script
# sequentially — a call placed above its definition dies with "command not found".
# The idempotency short-circuit calls ensure_branches, so it lives at the bottom.

# ------------------------------------------------------------------ CODEOWNERS
# GitHub SILENTLY IGNORES a CODEOWNERS entry whose team does not exist or lacks
# write access. So we verify, or we ship no file at all — never enforcement theater.
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
  local repo perm
  repo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo '')"
  if [ -n "${repo}" ]; then
    if perm=$(gh api "orgs/${ORG}/teams/${TEAM}/repos/${repo}" -q '.permissions.push' 2>&1); then
      [ "${perm}" = "true" ] || warn "team '${TEAM}' has no WRITE access to ${repo} — CODEOWNERS will be silently ignored until it does."
    else
      grep -qE '"status": *"404"|HTTP 404|Not Found' <<<"${perm}" \
        && warn "team '${TEAM}' is not attached to ${repo} — grant it write access or CODEOWNERS is inert." \
        || die "cannot check team write access (not a 404): ${perm}"
    fi
  fi

  sed "s|@${ORG}/TEAM_SLUG|@${ORG}/${TEAM}|" .github/CODEOWNERS.tmpl > .github/CODEOWNERS
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
    git push -u origin dev staging main
    info "pushed dev, staging, main"
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

# Remove templates/ ONLY. init-repo.sh does NOT delete itself: criterion 7 requires a re-run
# to be a no-op exiting 0, and a self-deleting script cannot be re-run. The re-run IS the
# recovery path for a first run that died partway. scripts/ keeps apply-rulesets.sh regardless.
rm -rf templates
info "removed templates/"

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
