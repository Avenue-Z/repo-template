#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=template-tests/lib.sh disable=SC1091
source template-tests/lib.sh

# ---------------------------------------------------------------------------------------
# THE TEMPLATE'S OWN BASH IS THE MACHINERY THAT CREATES EVERY AVENUE Z REPO. LINT IT.
#
# scripts/ and template-tests/ are ~3,600 lines of bash that select a stack, rewrite branch
# lineage, resolve CODEOWNERS, apply rulesets and link Vercel. Twelve files carry
# `# shellcheck source=` directives, so ShellCheck was already being run here — by hand. This
# case is what stops that discipline lapsing the day the person who remembers it stops.
#
# NOT payload: init-repo.sh deletes scripts/ and template-tests/, and there are no .sh files
# under templates/, so a generated repo has nothing for this to lint.
#
# Scope is EXPLICIT GLOBS, never `find . -name '*.sh'`: a working checkout has 46 .sh files
# against 23 tracked — 22 in the gitignored .claude/worktrees/ (a whole stale copy of this repo,
# including its own template-tests/*.sh) and one vendored in templates/next/node_modules/.
# Linting either means a red gate over code that cannot be fixed by changing this repository.
echo "shellcheck: the template's own bash is linted"

# A missing linter has verified NOTHING. lib.sh: "A skipped check is NOT a passed check."
# The tool assertion in template-tests.yml does not cover this path — it is a workflow step, and
# `bash template-tests/test_shellcheck.sh` never runs it. Without this check, `set -e` is
# suppressed inside the `if` below, so 127 flows into the else branch and every file reports
# FAIL: not fail-open but fail-MISATTRIBUTED, which reads as "your bash is broken".
if ! command -v shellcheck >/dev/null 2>&1; then
  fail "shellcheck is not installed — nothing was linted (brew install shellcheck | apt-get install shellcheck)"
  finish
fi

# The runner's ShellCheck is unpinned and rolls with the ubuntu-latest image, which is an accepted
# tradeoff (the image is already in this repo's trusted base). Print the version so that a red
# gate nobody's change caused is one glance to diagnose instead of a bisect.
printf '  using %s\n' "$(shellcheck --version | sed -n 's/^version: /shellcheck /p')"

# nullglob is LOAD-BEARING. Without it an unmatched glob expands to ITSELF, so the guard below
# counts 2 literal strings and passes vacuously — then hands them to ShellCheck as filenames.
shopt -s nullglob
files=(scripts/*.sh template-tests/*.sh)

# ...and this guard must EXIT, not fall through. fail() only increments a counter. On bash 3.2
# (/bin/bash on macOS) expanding an empty array under `set -u` is a fatal "unbound variable" —
# fixed in 4.4, so CI would never show it and only the laptop would break.
if [ "${#files[@]}" -eq 0 ]; then
  fail "no .sh files under scripts/ or template-tests/ — this test is not testing anything"
  finish
fi

# Per-file reporting, and the `if` is what makes it work: a naked `shellcheck "$f"` under the
# `set -e` inherited from lib.sh aborts at the FIRST offending file, so the reader learns about
# file 1 and never hears about 2..N. See lib.sh:36-37 for why `&& pass || fail` is not the fix.
for f in "${files[@]}"; do
  if out="$(shellcheck -S warning -f gcc "$f" 2>&1)"; then
    pass "$f"
  else
    fail "$f"
    printf '%s\n' "${out}" | sed 's/^/         /'
  fi
done

finish
