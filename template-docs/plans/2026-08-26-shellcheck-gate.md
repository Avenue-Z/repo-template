# ShellCheck Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **STATUS: EXECUTED, THEN AMENDED ON REVIEW.** Both tasks below landed as written. A
> post-implementation review then found five defects in what the gate was *aimed at* (not in how it
> was built), and the shipped code now differs from the step bodies below. **The Global Constraints
> immediately following are current and authoritative; the numbered step bodies are the historical
> record of the original execution and are superseded where they conflict.** The embedded commit
> messages in Steps 7 and 10 are reproduced verbatim from git and are deliberately not rewritten —
> two of their claims (`-S warning` "measured identical", SC1091 "below the warning floor") were
> corrected by the review. See `template-docs/reviews/2026-08-26-review-shellcheck-gate-impl.md`
> for the findings and their resolutions, and the design spec for the current rationale.

**Goal:** Lint the template's own ~3,600 lines of bash on every PR, as a case inside the existing
`template-tests` suite, so a discipline currently living in one maintainer's habits becomes a control.

**Architecture:** One new suite case (`template-tests/test_shellcheck.sh`) discovered automatically by
the runner loop already in `template-tests.yml`, plus one step in that workflow. No new workflow,
no new status-check context. **That workflow change is not what this plan originally described.** It
was "one line added to the tool assertion"; review removed that line (asserting there aborts all 15
suites before any runs) and then added a *conditional install* step instead, which is a different
thing — see Global Constraints below. Task 1 closes a real coverage gap the linter
exposes; Task 2 turns the linter on. **The order is load-bearing** — see below.

**Tech Stack:** bash, ShellCheck (preinstalled on the runner image, unpinned by decision), the
suite's own `template-tests/lib.sh` assertions. **Version matters and was originally misstated
here as "0.11.0 (preinstalled on `ubuntu-latest`)".** 0.11.0 was the *local* version every
"measured" claim in this plan was produced with; `ubuntu-24.04` ships **0.9.0**, and the two
disagree on this tree. Verify against 0.9.0, not your laptop, before trusting a measurement — the
suite prints the version it actually used for exactly this reason.

**Spec:** `template-docs/specs/2026-08-25-shellcheck-gate-design.md` — read it first. Its "What this
gate does NOT do" and "Three implementation landmines" sections are the reason this plan looks the
way it does, and the review log at `template-docs/reviews/2026-08-25-review-shellcheck-gate-spec.md`
records two rounds of defects that specifying it casually produced.

## Global Constraints

- **Severity is `-S info`.** Not `warning`, not `style`. `-S warning` does **not** report `SC2086`
  (unquoted expansion) at all — it is `info` severity — which exempted the first defect class this
  gate exists to catch, in scripts that run `rm -rf`. `info` is the lowest floor that keeps
  `SC2086` without the `style` tier. (Originally `-S warning`, on a "measured identical, chosen for
  headroom" argument that was measured only at 0.11.0 and only at `warning`.)
- **No `-x` / `--external-sources`.** Dropped after measurement — the `# shellcheck source=`
  directives carry `disable=SC1091` and suppress the only diagnostic it produces. (The original
  second clause, "and SC1091 is `note` severity, below the `warning` floor," no longer holds at
  `-S info` and was a non-sequitur regardless.) **Every file that sources `lib.sh` must carry the
  directive** — two did not, because they source through `${REPO_ROOT}`, and `-x` cannot resolve an
  interpolated path either.
- **Scope is explicit globs:** `scripts/*.sh` and `template-tests/*.sh`. **Never** `find . -name
  '*.sh'` — that returns 47 files against 24 tracked (22 in the gitignored `.claude/worktrees/`, one
  in `templates/next/node_modules/`). **The counts here are the SHIPPED ones (47/24), measured on
  disk and in the index after `test_shellcheck.sh` landed.** The 46/23 in the step bodies below was
  correct when the plan was written, one file earlier, and is left as part of that record.
- **The GATE is template-only; half of what it LINTS is not.** `init-repo.sh:359` deletes
  `templates/`, `template-tests/` and `template-docs/` **only** — `scripts/` survives by design
  (`:358`: "scripts/ keeps apply-rulesets.sh regardless"), so all 8 `scripts/*.sh` ship into every
  generated repo. This plan originally asserted `init-repo.sh` deletes `scripts/`; it does not.
  Nothing here may ship, so do not add anything under `templates/` — but understand that this repo
  is the **only** place those 8 payload scripts are ever linted.
- **Branch flow:** work on a `feat/*` or `chore/*` branch off `dev`. Never push to `main`.
  `CONTRIBUTING.md` is canonical.
- **Verify, don't infer.** Every "Expected:" block below was produced by actually running the
  command during planning. If yours differs, the difference is the finding — do not proceed past it.

---

## File Structure

| File | Responsibility |
|---|---|
| `template-tests/test_shellcheck.sh` | **Create.** The gate. Self-contained: guards its own preconditions, selects files, lints, reports per file. |
| `template-tests/test_apply_rulesets.sh` | **Modify** (after line 64). Add the two `--yes` assertions that the SC2034 is pointing at. |
| `.github/workflows/template-tests.yml` | **Modify — one step, and NOT the one written here originally.** ~~Add `shellcheck` to the tool assertion list.~~ Reversed on review: asserting it there aborts all 15 suites, where the suite's own guard reports one honest FAIL and lets the other 14 run. What ships instead is a **conditional install** step — `command -v` short-circuits on today's image, and it does not fail the job if the install fails. Asserting and installing are different questions and only the first was ever considered. No runner change either way; the runner loop already globs `template-tests/test_*.sh`. |

**Why Task 1 must land before Task 2:** the tree is not currently clean. `shellcheck -S warning`
reports one finding, so if the gate arrives first it goes red immediately on a defect that is not
the gate's fault. Verified at baseline:

```
template-tests/test_apply_rulesets.sh:60:4: warning: out_yes appears unused. Verify use (or export if used externally). [SC2034]
```

---

### Task 1: Close the `--yes` coverage gap in `test_apply_rulesets.sh`

The SC2034 is **not dead code**. `out_yes` (line 60) is the structural twin of `out_org` (line 51)
minus its assertions: the `--org` path checks the refusal message and that nothing was applied; the
`--yes` path — guarding what line 61 itself calls "a consent bypass [that] must not exist" — checks
an exit code and stops. Fix the test; do not delete the variable.

**Files:**
- Modify: `template-tests/test_apply_rulesets.sh` (insert after line 64, the `fi` closing the `--yes` block)

**Interfaces:**
- Consumes: `assert_match`, `assert_nomatch` from `template-tests/lib.sh` (already sourced at line 5)
- Produces: a tree that is clean at `shellcheck -S warning`, which Task 2 depends on

- [ ] **Step 1: Observe the finding that motivates this task**

```bash
shellcheck -S warning -f gcc template-tests/test_apply_rulesets.sh
```

Expected — exit 1, exactly one line:

```
template-tests/test_apply_rulesets.sh:60:4: warning: out_yes appears unused. Verify use (or export if used externally). [SC2034]
```

- [ ] **Step 2: Confirm the strings the assertions will match are real**

Do not take them from this plan on faith — the script is the source of truth:

```bash
./scripts/apply-rulesets.sh --yes --dry-run 2>&1 | head -3
grep -nE "created new ruleset|updated existing ruleset" scripts/apply-rulesets.sh
```

Expected: the first prints `ERROR there is no --yes on this script — it has nothing destructive to
confirm.` (exit 1). The second prints lines 149 and 153.

- [ ] **Step 3: Add the two assertions**

Insert immediately after the `fi` on line 64 (the one closing the `--yes` `if`/`else`), so the block
mirrors the `--org` block above it:

```bash
assert_match   "explains there is no --yes to reach for" 'no --yes on this script' "$out_yes"
assert_nomatch "does not apply anything" 'created new ruleset|updated existing ruleset' "$out_yes"
```

**The regex on the second line is deliberately NOT the one from line 57.** Line 57 guards the *org*
apply's messages (`created new org ruleset`); `apply-rulesets.sh:149,153` log the repo-level strings
without `org`. Copying line 57 verbatim would assert against output this code path cannot produce —
a vacuous check inside the fix for a vacuous check.

- [ ] **Step 4: Run the suite case and confirm both new assertions pass**

```bash
bash template-tests/test_apply_rulesets.sh
```

Expected — among the output, and ending `ALL PASS`:

```
apply-rulesets: --yes must NOT exist here either
  ok   --yes is refused by apply-rulesets.sh
  ok   explains there is no --yes to reach for
  ok   does not apply anything
```

- [ ] **Step 5: Confirm the tree is now clean**

```bash
shellcheck -S warning -f gcc scripts/*.sh template-tests/*.sh; echo "exit=$?"
```

Expected: no output, `exit=0`.

- [ ] **Step 6: Run the whole suite for regressions**

```bash
for t in template-tests/test_*.sh; do bash "$t" >/dev/null 2>&1 && echo "PASS $(basename $t)" || echo "FAIL $(basename $t)"; done
```

Expected: 14 lines, all `PASS`.

- [ ] **Step 7: Commit**

```bash
git add template-tests/test_apply_rulesets.sh
git commit -m "test: assert the --yes refusal message, not just its exit code

test_apply_rulesets.sh:60 captured out_yes and never read it — the structural twin of the --org
block above it, minus the assertions. The --org path checks the refusal message and that nothing
was applied; the --yes path, guarding what line 61 calls a consent bypass, checked an exit code and
stopped. ShellCheck's SC2034 was pointing at a coverage gap, not at cruft.

Note the nomatch regex differs from line 57's: that one guards the org apply's messages, while
apply-rulesets.sh:149,153 log the repo-level 'created new ruleset' / 'updated existing ruleset'.
Reusing line 57's pattern would have asserted against strings this path cannot emit.

Verified: the case reports 'ok explains there is no --yes to reach for' and 'ok does not apply
anything'; all 14 suites PASS; shellcheck -S warning over scripts/ and template-tests/ now exits 0."
```

---

### Task 2: Add the gate

**Files:**
- Create: `template-tests/test_shellcheck.sh`
- Modify: `.github/workflows/template-tests.yml:37`

**Interfaces:**
- Consumes: `pass`, `fail`, `finish` from `template-tests/lib.sh`; a tree that is clean at
  `-S warning` (Task 1)
- Produces: a 15th suite case, discovered automatically by the existing runner loop

- [ ] **Step 1: Create `template-tests/test_shellcheck.sh`**

**SUPERSEDED — do not copy this block.** It is the content as originally executed; every guard in
it was exercised (Steps 4–8) and all of them still stand. But the shipped file differs: severity is
now `-S info`, a tracked-`.sh` scope assertion was added, and the `NOT payload` comment below is
**factually wrong** (`init-repo.sh` does not delete `scripts/`). Read
`template-tests/test_shellcheck.sh` for the current version.

```bash
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
```

Then: `chmod +x template-tests/test_shellcheck.sh`

- [ ] **Step 2: Run it — expect green**

```bash
bash template-tests/test_shellcheck.sh
```

Expected: `using shellcheck 0.11.0` (or whatever your version is), then **24** `ok` lines — the 23
pre-existing files plus this new one, which lints itself — and `ALL PASS`.

If you see `FAIL template-tests/test_apply_rulesets.sh` with an SC2034, Task 1 was skipped. Stop and
do Task 1.

- [ ] **Step 3: Red-green — two violations at once, in real files**

Two, not one: a single failure cannot detect the `set -e` truncation this loop is written to avoid.
And **in-tree, not a scratch copy** — the explicit globs mean an out-of-tree copy is the one place
this gate is guaranteed not to look.

```bash
printf '\ndeliberate_violation_a=1\n' >> scripts/sca-gate.sh
printf '\ndeliberate_violation_b=1\n' >> scripts/link-vercel.sh
bash template-tests/test_shellcheck.sh 2>&1 | grep -A1 "FAIL scripts/"
```

Expected — **both** named, each with its finding indented beneath it:

```
  FAIL scripts/link-vercel.sh
         scripts/link-vercel.sh:354:1: warning: deliberate_violation_b appears unused. Verify use (or export if used externally). [SC2034]
  FAIL scripts/sca-gate.sh
         scripts/sca-gate.sh:96:1: warning: deliberate_violation_a appears unused. Verify use (or export if used externally). [SC2034]
```

If only one is named, the loop is aborting early — re-read landmine 1 in the spec.

- [ ] **Step 4: Revert the violations and confirm green again**

```bash
git checkout -- scripts/sca-gate.sh scripts/link-vercel.sh
git status --short scripts/
bash template-tests/test_shellcheck.sh | tail -1
```

Expected: `git status` prints nothing for `scripts/`; the run ends `ALL PASS`.

- [ ] **Step 5: Empty-glob guard — assert the MESSAGE, on both bash versions**

An unguarded version also exits non-zero (via `unbound variable` on bash 3.2, or ShellCheck's exit-3
usage dump on 5.x), so checking only that it went red proves nothing. Build a harness whose globs
match nothing:

```bash
SCRATCH="$(mktemp -d)"; mkdir -p "$SCRATCH/template-tests"
cp template-tests/lib.sh "$SCRATCH/template-tests/"
sed 's|files=(scripts/\*\.sh template-tests/\*\.sh)|files=(nope/*.sh alsonope/*.sh)|' \
  template-tests/test_shellcheck.sh > "$SCRATCH/template-tests/test_shellcheck.sh"
bash      "$SCRATCH/template-tests/test_shellcheck.sh"; echo "bash5 exit=$?"
/bin/bash "$SCRATCH/template-tests/test_shellcheck.sh"; echo "bash3.2 exit=$?"
```

Expected — **identical** under both, exit 1 each:

```
  FAIL no .sh files under scripts/ or template-tests/ — this test is not testing anything

1 FAILURE(S)
```

If `/bin/bash` prints `unbound variable` instead, the guard is falling through instead of calling
`finish`. That is the bug this step exists to catch; do not read the non-zero exit as success.
(On Linux, `/bin/bash` is 5.x and both runs are the same shell — the 3.2 path only differs on macOS.)

- [ ] **Step 6: Missing-ShellCheck, local path — one honest failure, not 24**

```bash
NOBIN="$(mktemp -d)"; mkdir -p "$NOBIN/tools"
for t in jq gh python3; do ln -sf "$(command -v $t)" "$NOBIN/tools/$t"; done
env PATH="$NOBIN/tools:/bin:/usr/bin" bash template-tests/test_shellcheck.sh; echo "exit=$?"
```

Expected — exactly one failure line, exit 1:

```
  FAIL shellcheck is not installed — nothing was linted (brew install shellcheck | apt-get install shellcheck)
```

If you get 24 `FAIL <file>` lines, the `command -v` guard is missing.

- [ ] **Step 7: Wrong-cwd sanity**

```bash
(cd template-tests && bash test_shellcheck.sh | grep -cE '^  (ok|FAIL) ')
```

Expected: `24`. The `cd "$(dirname "$0")/.."` is what makes this work; without it the relative globs
resolve against `template-tests/` and match far less.

- [ ] **Step 8: Add `shellcheck` to the workflow's tool assertion**

In `.github/workflows/template-tests.yml`, line 37:

```yaml
          for t in jq gh python3 bash; do
```

becomes:

```yaml
          for t in jq gh python3 bash shellcheck; do
```

Change nothing else. **Do not touch the runner loop at line 64** — `for t in template-tests/test_*.sh`
already discovers the new case.

Verify the edited loop fails on a missing ShellCheck specifically:

```bash
env PATH="$NOBIN/tools:/bin:/usr/bin" bash -c '
set -euo pipefail
for t in jq gh python3 bash shellcheck; do
  command -v "$t" >/dev/null || { echo "::error::$t is required by the suite but is not installed"; exit 1; }
  echo "ok: $t"
done'; echo "exit=$?"
```

Expected: `ok:` for the first four, then
`::error::shellcheck is required by the suite but is not installed`, exit 1.

- [ ] **Step 9: Full suite — now 15**

```bash
for t in template-tests/test_*.sh; do bash "$t" >/dev/null 2>&1 && echo "PASS $(basename $t)" || echo "FAIL $(basename $t)"; done
```

Expected: 15 lines, all `PASS`.

- [ ] **Step 10: Commit**

```bash
git add template-tests/test_shellcheck.sh .github/workflows/template-tests.yml
git commit -m "test: lint the template's own bash in CI

3,663 lines of bash across 23 files gate every Avenue Z repo and nothing linted them. Twelve files
carry '# shellcheck source=' directives and the tree is clean at -S warning, so ShellCheck was
already being run by hand — this is what stops that lapsing when the person who remembers it stops.

Rides the existing required 'template-tests' context rather than adding a status check that could
hang PRs PENDING FOREVER; no runner change needed, since line 64 already globs test_*.sh.

Guards, each verified by exercising it rather than by reading the code:
- command -v shellcheck in the SCRIPT, not only the workflow tool loop: set -e is suppressed inside
  an if condition, so 127 would flow into the else branch and report FAIL for all 24 files —
  fail-misattributed, which reads as 'your bash is broken'.
- shopt -s nullglob, and a guard that calls finish rather than falling through: without nullglob an
  unmatched glob expands to itself and the count check passes vacuously; without finish, expanding
  an empty array under set -u is fatal on bash 3.2 (/bin/bash on macOS) and invisible in CI.
- explicit globs, never find: a checkout has 46 .sh files against 23 tracked, 22 of them in the
  gitignored .claude/worktrees/ and one in templates/next/node_modules/.
- per-file if/pass/fail rather than a naked shellcheck: set -e would abort at the first offender.

-S warning (not style/info — measured identical today, chosen for headroom) and no -x (all 12
source= directives carry disable=SC1091, which is below the warning floor anyway).

Verified: 15/15 suites PASS; two simultaneous violations are both named; the empty-glob guard prints
its message identically under bash 5.x and /bin/bash 3.2; a missing linter produces one honest
failure, not 24."
```

---

## Done when

- [ ] `bash template-tests/test_shellcheck.sh` reports 24 `ok` lines and `ALL PASS`
- [ ] All 15 suites pass locally
- [ ] PR opened against `dev`; `template-tests`, `sca`, `secret-scan`, `guard-base-branch` all green
- [ ] The PR body states which guards were exercised and what was observed — not that they "should work"

## Notes for the executor

- **The spec's testing item 7 says "all 23 files."** That count predates this task; once
  `test_shellcheck.sh` exists the tree has 24 `.sh` files and the case lints itself. Expect 24.
- **Do not add a pre-commit hook.** Considered and rejected in the spec: `.pre-commit-config.yaml`
  states the CI job is the real gate, and a hook would make ShellCheck a local install requirement.
- **If ShellCheck flags something in a file you did not touch**, that is the unpinned-version
  tradeoff the spec accepts, not a reason to lower severity. The version line in the output tells you
  whether the linter moved. Fix the finding, or raise it — do not silence the gate.
