#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"

# Build a throwaway clone so we never mutate the real template.
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
git clone -q "${REPO_ROOT}" "${WORK}/repo"
cd "${WORK}/repo"
git checkout -qb dev 2>/dev/null || git checkout -q dev

echo "init-repo: python"
./scripts/init-repo.sh python --no-push

# Criterion 15 — no head carries templates/
assert_no_dir "templates/ removed from working tree" templates
for b in dev staging main; do
  if git ls-tree -r --name-only "$b" | grep -q '^templates/'; then
    fail "branch $b still contains templates/"
  else
    pass "branch $b is free of templates/"
  fi
done

# Criterion 3 — all three branches exist
for b in dev staging main; do
  assert_ok "branch $b exists" git show-ref --verify --quiet "refs/heads/$b"
done

# Criterion 1 — the python skeleton is real
assert_file "pyproject.toml copied" pyproject.toml
assert_file "ci.yml copied" .github/workflows/ci.yml

# Criterion 8 — no --team means no inert CODEOWNERS
assert_no_file "no CODEOWNERS without --team" .github/CODEOWNERS
assert_no_file "CODEOWNERS.tmpl removed" .github/CODEOWNERS.tmpl

# Criterion 7 — re-run is a no-op, exit 0
if ./scripts/init-repo.sh python --no-push; then pass "re-run exits 0"; else fail "re-run failed"; fi

# Criterion 11 — a bogus team WARNS and exits 0; it does not set -e crash
cd "${WORK}" && rm -rf repo2 && git clone -q "${REPO_ROOT}" repo2 && cd repo2
git checkout -qb dev 2>/dev/null || git checkout -q dev
if out=$(./scripts/init-repo.sh python --team definitely-not-a-real-team --no-push 2>&1); then
  pass "bogus --team exits 0 (guarded, not fatal)"
  assert_match "warned about the missing team" 'does not exist' "$out"
  assert_no_file "no CODEOWNERS written for a bogus team" .github/CODEOWNERS
else
  fail "bogus --team crashed instead of warning (set -e trap)"
fi

# Criterion 11 (the other half) — "I could not verify" is NOT "verified absent".
#
# THE PROJECT'S #1 INVARIANT. A 404 is an ANSWER (team absent -> warn, drop CODEOWNERS,
# exit 0). Anything else — expired auth, network, rate limit — is NOT an answer, and the
# script must DIE rather than silently downgrade the repo to no code-owner review. A bare
# `if ! gh api ...` treats a 401 exactly like a 404; that is the failure this test exists
# to catch. An invalid GH_TOKEN gives a real 401 from the real API, so this exercises the
# actual guard, not a mock of it.
cd "${WORK}" && rm -rf repo3 && git clone -q "${REPO_ROOT}" repo3 && cd repo3
git checkout -qb dev 2>/dev/null || git checkout -q dev
if out=$(GH_TOKEN=invalid_token_xyz ./scripts/init-repo.sh python --team automation --no-push 2>&1); then
  fail "unverifiable team (bad auth) exited 0 — a 401 was silently treated as 'team absent'"
else
  pass "unverifiable team (bad auth) exits non-zero"
fi
assert_match  "said it cannot verify the team" 'cannot verify' "$out"
assert_no_file "no CODEOWNERS written when the team could not be verified" .github/CODEOWNERS
assert_file    "CODEOWNERS.tmpl preserved (nothing dropped on an unverifiable answer)" .github/CODEOWNERS.tmpl

# Minor — `--team --no-push` must not set TEAM='--no-push'
cd "${WORK}/repo3"
if ./scripts/init-repo.sh python --team --no-push >/dev/null 2>&1; then
  fail "--team consumed the next flag as a slug"
else
  pass "--team rejects a value that begins with '-'"
fi

# Minor — the LIVE CODEOWNERS must not carry the template's "TEMPLATE — not live" preamble
cd "${WORK}" && rm -rf repo4 && git clone -q "${REPO_ROOT}" repo4 && cd repo4
git checkout -qb dev 2>/dev/null || git checkout -q dev
if ./scripts/init-repo.sh python --team automation --no-push >/dev/null 2>&1 && [ -f .github/CODEOWNERS ]; then
  live="$(cat .github/CODEOWNERS)"
  assert_nomatch "live CODEOWNERS has no 'TEMPLATE — not live' preamble" 'TEMPLATE .. not live' "$live"
  assert_match   "live CODEOWNERS names the resolved team" '@Avenue-Z/automation' "$live"
else
  # No network / no auth for the real team: skip rather than report a false failure.
  pass "skipped CODEOWNERS-preamble check (team 'automation' not resolvable in this env)"
fi

# Criterion (Important 6) — HEAD must be dev; a single-branch 'Use this template' copy
# lands the init commit on main and then dies mid-flight on `git push dev`.
cd "${WORK}" && rm -rf repo5 && git clone -q "${REPO_ROOT}" repo5 && cd repo5
git checkout -qb main 2>/dev/null || git checkout -q main
if out=$(./scripts/init-repo.sh python --no-push 2>&1); then
  fail "ran with HEAD=main — dev would be left stale and the push would die after the commit"
else
  pass "refuses to run when HEAD is not dev"
fi
assert_match "says HEAD is not dev" "not 'dev'" "$out"
assert_dir   "died BEFORE mutating the tree (templates/ intact)" templates

finish
