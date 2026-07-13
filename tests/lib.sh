#!/usr/bin/env bash
# Shared assertions for the repo-template test scripts.
set -euo pipefail

FAILURES=0

pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

assert_eq() { # <expected> <actual> <msg>
  if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (expected '$1', got '$2')"; fi
}

# git check-ignore exits 0 when the path IS ignored, 1 when it is not.
# --no-index is required: without it, git check-ignore consults the index,
# and a TRACKED file (e.g. .env.example) is always reported "not ignored"
# no matter what .gitignore says. That makes the assertion vacuous for any
# path that's already committed. --no-index forces pure pattern matching
# against .gitignore, which is what these assertions are meant to verify.
# Do not "simplify" this away.
assert_ignored() {
  if git check-ignore --no-index -q "$1"; then pass "$1 is ignored"; else fail "$1 should be ignored"; fi
}

assert_trackable() {
  if git check-ignore --no-index -q "$1"; then fail "$1 should be trackable but is ignored"; else pass "$1 is trackable"; fi
}

finish() {
  if [ "$FAILURES" -eq 0 ]; then printf '\nALL PASS\n'; exit 0; fi
  printf '\n%d FAILURE(S)\n' "$FAILURES"; exit 1
}
