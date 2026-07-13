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
[ ! -d templates ] && pass "templates/ removed from working tree" || fail "templates/ still present"
for b in dev staging main; do
  if git ls-tree -r --name-only "$b" | grep -q '^templates/'; then
    fail "branch $b still contains templates/"
  else
    pass "branch $b is free of templates/"
  fi
done

# Criterion 3 — all three branches exist
for b in dev staging main; do
  git rev-parse --verify -q "$b" >/dev/null && pass "branch $b exists" || fail "branch $b missing"
done

# Criterion 1 — the python skeleton is real
[ -f pyproject.toml ] && pass "pyproject.toml copied" || fail "pyproject.toml missing"
[ -f .github/workflows/ci.yml ] && pass "ci.yml copied" || fail "ci.yml missing"

# Criterion 8 — no --team means no inert CODEOWNERS
[ ! -f .github/CODEOWNERS ] && pass "no CODEOWNERS without --team" || fail "inert CODEOWNERS shipped"
[ ! -f .github/CODEOWNERS.tmpl ] && pass "CODEOWNERS.tmpl removed" || fail "CODEOWNERS.tmpl left behind"

# Criterion 7 — re-run is a no-op, exit 0
if ./scripts/init-repo.sh python --no-push; then pass "re-run exits 0"; else fail "re-run failed"; fi

# Criterion 11 — a bogus team WARNS and exits 0; it does not set -e crash
cd "${WORK}" && rm -rf repo2 && git clone -q "${REPO_ROOT}" repo2 && cd repo2
git checkout -qb dev 2>/dev/null || git checkout -q dev
if out=$(./scripts/init-repo.sh python --team definitely-not-a-real-team --no-push 2>&1); then
  pass "bogus --team exits 0 (guarded, not fatal)"
  grep -qi 'does not exist' <<<"$out" && pass "warned about the missing team" || fail "no warning emitted"
  [ ! -f .github/CODEOWNERS ] && pass "no CODEOWNERS written for a bogus team" || fail "wrote CODEOWNERS anyway"
else
  fail "bogus --team crashed instead of warning (set -e trap)"
fi

finish
