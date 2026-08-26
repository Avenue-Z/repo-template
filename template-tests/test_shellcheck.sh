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
# HALF OF THIS IS PAYLOAD. init-repo.sh:359 deletes templates/, template-tests/ and
# template-docs/ ONLY — scripts/ survives by design (:358, "scripts/ keeps apply-rulesets.sh
# regardless"), and test_init_repo.sh asserts sca-gate.sh, bandit-gate.sh and
# ci-aggregate-gate.sh are still there afterwards. So all 8 scripts/*.sh ship into every
# generated repo. That RAISES the stakes here: this is the only place they are ever linted,
# because the gate itself lives in template-tests/ and does not ship. A defect that clears this
# check is copied into every repo built from the template.
#
# Scope is EXPLICIT GLOBS, never `find . -name '*.sh'`: a working checkout has 47 .sh files
# against 24 tracked — 22 in the gitignored .claude/worktrees/ (a whole stale copy of this repo,
# including its own template-tests/*.sh) and one vendored in templates/next/node_modules/.
# Linting either means a red gate over code that cannot be fixed by changing this repository.
echo "shellcheck: the template's own bash is linted"

# A missing linter has verified NOTHING. lib.sh: "A skipped check is NOT a passed check."
# This is deliberately NOT in template-tests.yml's pre-flight tool loop. That loop exists for a
# suite that DIES on a missing tool and reports as a code failure; this one does not die, it
# reports one honest FAIL and the other 14 suites still run. Asserting shellcheck there instead
# would abort all 15 suites before any of them ran — strictly worse diagnostics for the same
# condition. Note `set -e` is suppressed inside an `if`, so without this guard 127 would flow
# into the else branch below and every file would report FAIL: not fail-open but
# fail-MISATTRIBUTED, which reads as "your bash is broken".
if ! command -v shellcheck >/dev/null 2>&1; then
  fail "shellcheck is not installed — nothing was linted (brew install shellcheck | apt-get install shellcheck)"
  finish
fi

# The runner's ShellCheck is unpinned and rolls with the ubuntu-latest image, which is an accepted
# tradeoff (the image is already in this repo's trusted base). This is NOT hypothetical drift:
# ubuntu-24.04 ships 0.9.0, and 0.9.0 reports two SC2015 findings on this tree that 0.11.0 does
# not. Both were fixed rather than silenced, so the tree is clean on both — but that is why the
# version is printed. A red gate nobody's change caused is then one glance to diagnose.
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

# ---------------------------------------------------------------------------------------
# TAMPER-EVIDENCE ON SCOPE. The globs above are a decision, not a discovery: a shell script added
# under templates/ or .github/scripts/ is silently never linted and this suite still prints ALL
# PASS. That is the same silent decay test_action_pins.sh guards against, so use the same idiom — a
# lockstep assertion that the linted set covers every TRACKED shell script.
#
# TRACKED, not on-disk, is the whole point: `git ls-files` cannot see .claude/worktrees/ or
# templates/next/node_modules/, which are exactly what the globs exist to exclude. Adding a
# script outside the globs is then a decision you have to make on purpose — widen the scope, or
# exclude it here with a reason.
#
# An assertion that can pass VACUOUSLY is worse than no assertion: it prints `ok` over an unchecked
# scope. Three ways this one could, all closed below.
#
# (1) `git ls-files` FAILING. Outside a checkout, on `detected dubious ownership` (a uid mismatch
# inside a container), or on a locked index, it writes nothing to stdout and exits 128. Piped
# straight into grep that is indistinguishable from "zero tracked files, all covered" — reproduced:
# it prints `ok all 0 tracked .sh files are covered` and then ALL PASS. So its status is CHECKED,
# not discarded into a pipeline, and a failed lookup is a FAIL: scope is UNVERIFIED, not clean.
if ! tracked="$(git ls-files)"; then
  fail "git ls-files failed — not a checkout, dubious ownership, or a locked index. Scope is UNVERIFIED, not clean"
  finish
fi

# (2) Keying on `*.sh` alone. A tracked EXTENSIONLESS script — `scripts/foo` opening
# `#!/usr/bin/env bash` — evades the globs AND this assertion, and the suite still prints ALL PASS.
# None exist today (verified), which is exactly when closing it is free rather than a migration.
# So the shebang decides, not the filename. `#!`...`sh` covers sh/bash/dash/ksh/zsh; the second
# pattern is the same line carrying an argument (`#!/bin/bash -e`). A `case` glob, not `grep -E`:
# `\b` is a GNU extension and this suite runs on macOS's BSD grep too.
shell_scripts=()
while IFS= read -r t; do
  case "$t" in
    '') continue ;;
    *.sh) shell_scripts+=("$t"); continue ;;
  esac
  [ -f "$t" ] || continue
  case "$(head -n 1 -- "$t" 2>/dev/null)" in
    '#!'*sh | '#!'*sh\ *) shell_scripts+=("$t") ;;
  esac
done <<< "$tracked"

# (3) Zero results. Same class as the empty-array guard fifteen lines above, and the same fix — this
# must EXIT, because fail() only increments a counter and the next line expands the array.
if [ "${#shell_scripts[@]}" -eq 0 ]; then
  fail "git ls-files reported no tracked shell scripts at all — this assertion is not asserting anything"
  finish
fi

# grep -F takes a multi-line argument as multiple patterns; -x anchors each to a whole line.
echo "shellcheck: every tracked shell script is in the linted set"
if unlinted="$(printf '%s\n' "${shell_scripts[@]}" | grep -vxF "$(printf '%s\n' "${files[@]}")")"; [ -n "$unlinted" ]; then
  fail "tracked shell script(s) outside the linted globs — widen the scope above or exclude them deliberately:"
  printf '%s\n' "$unlinted" | sed 's/^/         /'
else
  pass "all ${#shell_scripts[@]} tracked shell scripts are covered by the globs"
fi

# ---------------------------------------------------------------------------------------
# SEVERITY IS -S info, AND THAT FLOOR IS THE POINT OF THE GATE.
#
# SC2086 (unquoted expansion — word splitting and globbing) is `info` severity. At `-S warning`
# it is not reported AT ALL: `f="$1"; rm -rf $f` passes clean. These scripts run `rm -rf` and
# rewrite branch protection, so unquoted expansion is the first defect class this gate exists to
# catch, and `warning` silently exempts it. `info` is the lowest floor that keeps SC2086 without
# pulling in the `style` tier.
#
# Per-file reporting, and the `if` is what makes it work: a naked `shellcheck "$f"` under the
# `set -e` inherited from lib.sh aborts at the FIRST offending file, so the reader learns about
# file 1 and never hears about 2..N. See lib.sh:36-37 for why `&& pass || fail` is not the fix.
for f in "${files[@]}"; do
  if out="$(shellcheck -S info -f gcc "$f" 2>&1)"; then
    pass "$f"
  else
    fail "$f"
    printf '%s\n' "${out}" | sed 's/^/         /'
  fi
done

finish
