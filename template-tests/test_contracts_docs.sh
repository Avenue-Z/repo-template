#!/usr/bin/env bash
# The data-contract integration is DOCUMENTATION + one inert beacon. repo-template scaffolds no
# contract wiring — `contract init`, run by the adopter in the finished repo, owns the entire
# scaffold. So this suite proves exactly that: the beacon ships inert to python (and not to
# node/next), the README/CLAUDE pointers survive init, and nothing live was generated. The proof
# that a scaffolded tree actually lints lives in Avenue-Z/data-contract's own tests (init §10), not
# here — re-proving it would mean installing contract-core on a runner holding only a repo-scoped
# GITHUB_TOKEN.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${REPO_ROOT}/template-tests/lib.sh"

# Throwaway clones so we never mutate the real template (pattern from test_init_repo.sh).
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# --- python: the beacon ships, inert ---
echo "contracts-docs: python — beacon ships inert, README/CLAUDE pointers survive init"
git clone -q "${REPO_ROOT}" "${WORK}/py"
cd "${WORK}/py"
git checkout -qb dev 2>/dev/null || git checkout -q dev
./scripts/init-repo.sh python --no-push >/dev/null || { echo "init-repo python failed"; exit 1; }

assert_file    "beacon copied into the python repo" .github/workflows/contract.yml.example
assert_no_file "no LIVE contract workflow was scaffolded" .github/workflows/contract.yml
beacon="$(cat .github/workflows/contract.yml.example)"
# The .example suffix is load-bearing: a .yml with no `on:` trigger reports as a workflow
# error in the Actions tab of every generated repo.
assert_nomatch "beacon declares no workflow triggers" '^on:'    "$beacon"
assert_nomatch "beacon declares no jobs"              '^jobs:'  "$beacon"
# test_action_pins.sh globs templates/*/.github/workflows/*.yml, so a .example escapes the
# SHA-pin audit. No `uses:` line means there is nothing for it to have missed.
assert_nomatch "beacon references no actions (closes the pin-audit gap)" 'uses:' "$beacon"
# A literal tag here would be a second source of truth that goes stale — the rot
# Avenue-Z/data-contract PR #58 removed from the teaching template.
assert_nomatch "beacon pins no version tag" '@v[0-9]' "$beacon"
assert_match   "beacon names contract init as the way in" 'contract init' "$beacon"

# --- python: the README pointer survived init ---
readme="$(cat README.md)"
assert_match "README documents data contracts"        '## Data contracts' "$readme"
assert_match "README routes to contract init"         'contract init'     "$readme"
assert_match "README states the python-only limit"    'Python only'       "$readme"
assert_match "README names the 3.13 requirement"      '3\.13'             "$readme"
# init §2.1.1 rejects a dotted --platform. `google.ads` is the obvious thing to type, so the
# docs must say so before the adopter hits a refusal.
assert_match "README warns against a dotted --platform" 'google\.ads'     "$readme"
assert_match "CLAUDE.md carries the contracts rule"   'contract init'     "$(cat CLAUDE.md)"

# The docs the adopter needs must not have shipped — the adoption playbook is the template's, and
# the generated repo's equivalent pointer is the README section asserted above.
assert_no_file "adoption playbook still stripped" docs/ADOPTION.md

# --- node: the beacon must NOT ship ---
echo "contracts-docs: node — no beacon, but the README still explains why there is no node path"
git clone -q "${REPO_ROOT}" "${WORK}/node"
cd "${WORK}/node"
git checkout -qb dev 2>/dev/null || git checkout -q dev
./scripts/init-repo.sh node --no-push >/dev/null || { echo "init-repo node failed"; exit 1; }

assert_no_file "node repo carries no contract beacon" .github/workflows/contract.yml.example
assert_no_file "node repo carries no contract workflow" .github/workflows/contract.yml
# The README pointer DOES ship to node — it is how a node reader learns there is no path.
assert_match "node README explains there is no node path" 'no node/next path' "$(cat README.md)"

# --- the template's own tree: the beacon must stay python-only at source ---
cd "${REPO_ROOT}"
assert_file    "beacon is present in the python stack"  templates/python/.github/workflows/contract.yml.example
assert_no_file "beacon is not in the node stack" templates/node/.github/workflows/contract.yml.example
assert_no_file "beacon is not in the next stack" templates/next/.github/workflows/contract.yml.example

finish
