#!/usr/bin/env bash
# Private Python packages install from the Avenue Z index, with no GitHub token, and the only place
# a new repo learns that is its generated README. This suite proves the section survives init on
# python and that the docs never drift back to the advice that sent projects after a GitHub token.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=template-tests/lib.sh disable=SC1091
source "${REPO_ROOT}/template-tests/lib.sh"

INDEX='us-python\.pkg\.dev/avenue-z-shared-artifacts/python/simple/'

# Throwaway clone so we never mutate the real template (pattern from test_init_repo.sh).
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

echo "private-index-docs: python — the section survives init"
git clone -q "${REPO_ROOT}" "${WORK}/py"
cd "${WORK}/py"
git checkout -qb dev 2>/dev/null || git checkout -q dev
./scripts/init-repo.sh python --no-push >/dev/null || { echo "init-repo python failed"; exit 1; }

readme="$(cat README.md)"
assert_match "README documents the index"           '## Private Python packages' "$readme"
assert_match "README names the index URL"           "$INDEX"                     "$readme"
assert_match "README names the keyring plugin"      'keyrings\.google-artifactregistry-auth' "$readme"
assert_match "README shows the uv index block"      'tool\.uv\.index'            "$readme"
assert_match "README shows uv how to reach keyring" 'keyring-provider'           "$readme"
assert_match "README shows keyless CI"              'pkg-reader@'                "$readme"
assert_match "README says how to get reader access" 'reader binding'             "$readme"
# python-ci.yml installs with no index auth, so this warning is what stops the first private
# dependency from sending someone after a PAT when `ci` goes red.
assert_match "README says the shared python-ci cannot reach the index" 'python-ci.*(no|without) .*index' "$(tr '\n' ' ' <README.md)"
assert_match "README says --extra-index-url is forbidden" 'never .?--extra-index-url' "$readme"
assert_match "pyproject.toml points at the section" 'Private Python packages' "$(cat pyproject.toml)"

# A literal version here goes stale the day a release publishes, and a GitHub tag can already be
# ahead of the index, so an exact-looking pin can be one that does not install.
assert_nomatch "README pins no client version" '(glean-chat-api-client|drive-api-client)==[0-9]' "$readme"

echo "private-index-docs: no doc tells anyone to install the clients from GitHub"
cd "${REPO_ROOT}"
stale="$(grep -rIlE '(git\+ssh|git\+https)[^ ]*(glean-chat-api-client|drive-api-client)' \
  README.md README.repo.tmpl CONTRIBUTING.md docs templates || true)"
assert_eq "" "$stale" "no README, docs or starter file installs the clients over git"

finish
