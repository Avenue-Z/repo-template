# ShellCheck gate for the template's own bash — design

## Why this exists

The template was **3,663 lines of bash across 23 files** — 8 in `scripts/`, 15 in
`template-tests/` — when this spec was written, and is 3,772 across 24 with the gate itself
counted.
That bash is the machinery that creates every Avenue Z repo: it selects a stack, rewrites branch
lineage, resolves CODEOWNERS, applies rulesets, and links Vercel. Nothing lints it. Not in CI, not
in `.pre-commit-config.yaml`.

It is not unlinted because nobody cares. Twelve of those files carry `# shellcheck source=...`
directives, and at `-S warning` the entire tree produces **exactly one finding**
(`template-tests/test_apply_rulesets.sh:60`, SC2034 — `out_yes` assigned and never read). Someone
is running ShellCheck by hand and acting on it.

**That "exactly one" was the wrong number to design against, in two ways at once**, and the
post-implementation review caught both. It was measured at `-S warning` on ShellCheck **0.11.0**;
the gate now runs at `-S info` (see Rejected) and CI runs **0.9.0**, because that is what
`ubuntu-24.04` ships. Against that real combination the tree carried **four more** findings:
two `SC2015` (`A && B || C` in the org-plan guards of `apply-rulesets.sh` and
`apply-org-ruleset.sh`, reported by 0.9.0 and *not* by 0.11.0) and two `SC1091` (the two suites
that source `lib.sh` through `${REPO_ROOT}` and so never got the house `# shellcheck source=`
directive — visible only per-file, since a batched run has `lib.sh` among its inputs). All four
are fixed. The lesson is the spec's own: a number that was never measured under the conditions
the control actually runs in is an assumption wearing a measurement's clothes.

That is precisely the problem. This repo's stated posture is that no layer practices enforcement
theater and that "a failure to verify is never treated as a verified pass." An informal discipline
that lives in a maintainer's habits is the one control here that lapses silently — it survives
exactly as long as the person who remembers it. The gate is not being added because the code is
dirty; it is being added because the code is clean and nothing holds it there.

Adoption cost is **writing the two assertions the SC2034 is pointing at** — see the next section.

## The single existing finding is a missing assertion, not dead code

`template-tests/test_apply_rulesets.sh:60` assigns `out_yes` and never reads it. It is tempting to
read that as cruft and delete it. It is not cruft. Lines 51–64 are two structurally identical
blocks:

```bash
51  if out_org=$(./scripts/apply-rulesets.sh --org --dry-run 2>&1); then
    #   ...fail/pass on the exit code...
56  assert_match   "points the operator at the separate org script" 'apply-org-ruleset\.sh' "$out_org"
57  assert_nomatch "does not apply anything" 'created new org ruleset|updated existing org ruleset' "$out_org"

60  if out_yes=$(./scripts/apply-rulesets.sh --yes --dry-run 2>&1); then
    #   ...fail/pass on the exit code, and then nothing. No assertions on the output.
```

The `--org` path checks the refusal *message* and that nothing was applied. The `--yes` path — which
the test's own line 61 calls "a consent bypass [that] must not exist" — checks an exit code and
stops. Someone stopped halfway, and the unread variable is the scar.

So ShellCheck's first enforced run finds a real defect in the test suite. Deleting the variable
would delete the evidence and leave the missing coverage in place — which is the baseline mechanism
this spec rejects further down, just cheaper to write and harder to notice. **Fix the test.**

The assertions mirror 56–57 against strings the script actually emits (verified by running it):

```bash
assert_match   "explains there is no --yes to reach for" 'no --yes on this script' "$out_yes"
assert_nomatch "does not apply anything" 'created new ruleset|updated existing ruleset' "$out_yes"
```

Note the regex differs from line 57's: that one guards the *org* apply's messages, while
`apply-rulesets.sh:149,153` log `updated existing ruleset` / `created new ruleset` for the repo-level
apply. Reusing line 57's regex verbatim would assert against strings this code path cannot produce —
a vacuous check, which is the failure mode this whole document is about.

## What this gate does NOT do

Stated plainly, in the template's own idiom:

- **It does not ship into generated repos — but half of what it lints does.** The original
  wording here claimed `init-repo.sh` deletes `scripts/`. It does not. `init-repo.sh:359` removes
  `templates/`, `template-tests/` and `template-docs/` only, and `:358` says so outright —
  "scripts/ keeps apply-rulesets.sh regardless" — while `test_init_repo.sh:50` and
  `:55-56` assert `sca-gate.sh`, `bandit-gate.sh` and `ci-aggregate-gate.sh` survive. So **all 8 `scripts/*.sh`
  ship into every generated repo.** The *gate* is template-only (it lives in `template-tests/`),
  and that asymmetry is the point worth stating: this repo is the **only** place those 8 payload
  scripts are ever linted, so a defect that clears this check is copied into every repo built from
  the template. That raises the stakes on the severity floor rather than lowering them. Extending
  the gate into generated repos is a separate decision — see Out of scope.
- **It does not reason across files.** ShellCheck is single-file static analysis. It cannot know
  that `apply-rulesets.sh` sends a malformed ruleset payload, that a `gh api` call queries the wrong
  field, or that a guard fails open. That is what the 14 behavioural suites are for. This gate
  catches the class below that: unquoted expansions, unreachable branches, misused test operators,
  dead assignments.
- **It does not enforce style.** Severity is `-S info`, not `style`. It is deliberately **not**
  `warning`: `SC2086` (unquoted expansion — word splitting and globbing) is `info` severity, so
  `-S warning` does not report it *at all*. `f="$1"; rm -rf $f` passes clean at `warning`. These
  scripts run `rm -rf` and rewrite branch protection, which makes unquoted expansion the first
  defect class the gate exists to catch, and `warning` silently exempted it. `info` is the lowest
  floor that keeps `SC2086` without buying into the `style` tier; see Rejected.
- **It does not check bash embedded in workflow `run:` blocks.** ShellCheck reads shell files, not
  YAML. Several of this repo's most load-bearing shell lives inline in `sca.yml` and `ci.yml` and
  stays unlinted. Closing that needs `actionlint`, which is a separate decision with its own
  supply-chain question (see Out of scope).

## Decision: a suite case, not a new workflow

`template-tests/test_shellcheck.sh`, run by the existing loop in `template-tests.yml`.

The alternative — a dedicated `shellcheck` workflow — means a **new status-check context**. This
repo is emphatic about that cost: `template-tests.yml`'s own header records that a required check
which never reports does not fail a PR, it "hangs it PENDING FOREVER and nothing can be merged,"
which is why `template-tests` is added to the required set *conditionally* by `apply-rulesets.sh`.
Buying that problem again, for a gate that is one command, is a bad trade. Riding the existing
required context costs nothing and inherits the conditional-registration logic already in place.

## Decision: explicit globs, never a recursive find

The file list is `scripts/*.sh` and `template-tests/*.sh` — globs, so a script added tomorrow is
covered the day it lands, with no list to update.

It must **not** be `find . -name '*.sh'`. Measured on a working checkout today:

| | Files |
|---|---|
| `git ls-files '*.sh'` — what is actually in the repo | **24** |
| `find . -name '*.sh'` | **47** |
| …of which `.claude/worktrees/item-4-bandit-sast/` | 22 |
| …of which `templates/next/node_modules/` | 1 |

The worktree is a complete stale copy of the repo including its own `template-tests/*.sh`; it is
gitignored (`.gitignore:26`) and untracked, so it is invisible to git and harmless — until a
recursive walk lints it. `node_modules` is the second source, present on any checkout where someone
has run `npm ci`, and it is third-party code this repo does not own at all.

A recursive find therefore doubles the file count with material nobody can fix by changing the
repository: the gate would go red over a months-old duplicate of this suite, or over a vendored
dependency. Both are unfixable-by-design, which makes the gate something to be disabled rather than
satisfied.

## Decision: a missing ShellCheck fails the run, never skips it — in BOTH entry points

`lib.sh` states it directly: "A skipped check is NOT a passed check, and must never read like one."
A linter that isn't installed has verified nothing, and reporting green on that basis is the exact
fail-open pathology `sca.yml` refuses ("refusing to report a clean check").

This needs **one** change, in the test script itself — not two. The spec originally called for
`shellcheck` to join the tool assertion at the top of `template-tests.yml` as well; review showed
that is not merely redundant but **strictly worse**, and it has been dropped:

```yaml
for t in jq gh python3 bash; do          # shellcheck deliberately absent
```

That loop's own stated rationale is "a suite that **dies** on a missing tool reports as a code
failure." This suite does not die — it reports one honest `FAIL` and returns, so the other 14
suites still run and still report. Asserting `shellcheck` in the pre-flight loop would abort all
15 before any of them ran, discarding a guard that is already correct and trading fifteen results
for one error annotation. The in-script guard is the control; the loop entry was insulation
against a failure mode that cannot occur here.

**In the test script itself**, `command -v shellcheck` or `fail` + `finish`. This is the only
entry point that matters, and it covers both: the workflow runs the same script a contributor runs
with `bash template-tests/test_shellcheck.sh`. Without an in-script check the failure is not
fail-open, it is **fail-misattributed**, which is worse than the
honest skip this section forbids. Verified — `set -e` is suppressed inside an `if` condition, so a
`command not found` (127) flows straight into the `else` branch and the loop runs to completion:

```
  FAIL fileA
  FAIL fileB
  FAIL fileC
loop completed, set -e did not fire
```

A contributor without ShellCheck installed sees 23 lines of `FAIL <file>` and concludes their bash
is broken. The Decision is only true where this document claims it if both halves exist.

## Decision: the file list must be non-empty — and the guard needs `nullglob` to work at all

Borrowed verbatim in spirit from `test_action_pins.sh`, which fails with "no remote actions found in
any workflow — this test is not testing anything." A gate that lints zero files passes trivially and
looks identical to a gate that lints everything.

**The obvious implementation of this guard does not fire.** Bash does not enable `nullglob` by
default, so a glob matching nothing expands to *itself*, as a literal string. Measured:

```
$ files=(scripts/*.sh template-tests/*.sh)     # run in an empty directory, bash
count=2
  [scripts/*.sh]
  [template-tests/*.sh]
```

A `[ ${#files[@]} -eq 0 ]` check passes vacuously on two unexpanded globs, which then reach
ShellCheck as filenames and produce `openBinaryFile: does not exist` with exit 2. The case does go
red — for entirely the wrong reason, having never executed the branch that exists to catch this.

So the implementation **must** `shopt -s nullglob` before building the array, then count. Without
it, this named Decision is decoration: a guard against vacuous checks that is itself vacuous, in the
one document arguing that unverified controls are the problem.

**And the guard must stop the script — `fail "…"; finish` — not report and fall through.** `fail()`
only increments a counter; it does not exit. Falling through hits two separate failures before the
tester ever sees the message:

1. **`set -u` + an empty array is fatal on bash 3.2**, which is `/bin/bash` on every macOS machine —
   including the one a maintainer would verify this from. Expanding `"${files[@]}"` when the array
   is empty raises `unbound variable`. Measured on `GNU bash, version 3.2.57(1)-release`:

   ```
   count=0
   /bin/bash: line 1: f[@]: unbound variable
   ```

   Fixed in bash 4.4; `ubuntu-latest` runs 5.x, so **CI would never show this.** That is the same
   failure class `template-tests.yml:42-46` already records — "It passed on my machine only because
   my git happened to be configured" — running in the opposite direction: green in CI, crash on the
   laptop.
2. **Zero-arg ShellCheck exits 3 with a full usage dump**, not 1 — so even on modern bash the
   fall-through produces a wall of help text rather than the sentence the tester was told to look
   for.

## Wiring

| File | Change |
|---|---|
| `template-tests/test_shellcheck.sh` | **New.** In order: `cd "$(dirname "$0")/.."`, source `lib.sh`, `command -v shellcheck` or `fail`+`finish`, `shopt -s nullglob`, glob both dirs, **`fail`+`finish` if the count is zero**, echo `shellcheck --version`, **assert every tracked SHELL SCRIPT is inside the globs**, run `shellcheck -S info` per file reporting `pass`/`fail`, `finish`. The scope assertion has three vacuous-pass guards of its own: `git ls-files`' **exit status is checked** (outside a checkout, on dubious ownership, or on a locked index it prints nothing and exits 128 — piped into `grep` that reads as "0 tracked, all covered" and the suite prints ALL PASS), the result set must be **non-empty**, and membership is decided by **shebang, not by the `.sh` suffix**, so a tracked extensionless `#!/usr/bin/env bash` script cannot evade both the globs and the guard. |
| `.github/workflows/template-tests.yml` | **Modify — one step.** The runner loop already globs `template-tests/test_*.sh`, so the case is *discovered* automatically, and `shellcheck` is still deliberately **not** added to the pre-flight tool loop (see the entry-points decision above — asserting it there would abort all 15 suites). But *asserting* and *installing* are different questions, and nothing was doing the latter: the gate rested on `ubuntu-latest` happening to ship the binary. Add a conditional install step — `command -v` short-circuits on today's image, so the normal path is untouched — that **does not fail the job** if the install fails, leaving the missing-linter case to the suite's own honest FAIL. Without it, an image rotation that drops `shellcheck` turns a required check permanently red with no fix available inside this repository. |
| `scripts/apply-rulesets.sh`, `scripts/apply-org-ruleset.sh` | **Modify.** Rewrite the org-plan `[ -n ] && [ != null ] || die` guards as `if [ -z ] || [ = null ]; then die; fi`. `SC2015`, surfaced only by ShellCheck 0.9.0 at `-S info`. Behaviour is identical by De Morgan, re-verified by driving both scripts with a fake `gh` returning an empty plan. |
| `template-tests/test_contracts_docs.sh`, `template-tests/test_init_repo.sh` | **Modify.** Add the house `# shellcheck source=template-tests/lib.sh disable=SC1091` directive. Both source through `${REPO_ROOT}` and so never picked it up; `SC1091` fires per-file at `-S info`. |
| `template-tests/test_apply_rulesets.sh` | **Add the two missing `--yes` assertions** (see above), which is what makes `out_yes` read. Do not delete the variable. |

Per-file reporting rather than one aggregate pass matters for the same reason `test_action_pins.sh`
names the offending SHA: a gate that says only "shellcheck failed" makes the reader re-run the tool
locally to learn anything.

## Three implementation landmines the plan must handle explicitly

These are the ways this gets built wrong. Named here because each one produces a gate that looks
like it works.

1. **`set -e` will silently truncate the per-file loop.** `lib.sh:3` is `set -euo pipefail`, and it
   is sourced. A naked `shellcheck "$f"` inside a `for` loop aborts the whole script at the *first*
   offending file — verified: a three-iteration loop with a failing command prints one line and
   exits 1. The reader sees file 1 and never learns 2..N, landing on exactly the "gate that says
   only shellcheck failed" opacity that per-file reporting exists to prevent. Use the house idiom —
   `assert_ok`, or an explicit `if …; then pass; else fail; fi`. Note `lib.sh:36-37` already documents
   why `cmd && pass || fail` is *not* if-then-else here (SC2015); do not reach for it.
2. **`nullglob`, and a guard that exits rather than falls through** — per the Decision above. Both
   halves, or the guard crashes on bash 3.2 before it can report.
3. **The `cd` is a precondition, not boilerplate.** The suite has two cwd idioms: eleven cases open
   with `cd "$(dirname "$0")/.."` and source relatively; `test_init_repo.sh`,
   `test_link_vercel.sh`, and `test_contracts_docs.sh` instead set
   `REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"` and source absolutely, because they `cd`
   elsewhere later. **This case must use the first idiom**, and it is not optional: the entire
   file-selection mechanism is *relative* globs, so without the `cd` they resolve against the
   caller's directory. Combined with landmine 2, `cd template-tests && bash test_shellcheck.sh`
   would match nothing and — unguarded, on bash 3.2 — die with `unbound variable` instead of
   reporting anything at all.

## Testing

1. **Green:** the full suite passes 15/15 (14 existing + the new case).
2. **Red-green, not just green.** A gate that has never been observed failing is not known to work.
   Introduce a deliberate violation **in a real file under `scripts/` or `template-tests/`**,
   confirm the suite goes red and names that file, then revert and confirm green. It must not be a
   scratch copy: the explicit globs exist precisely so out-of-tree copies are never linted, making a
   scratch copy the one location where the gate is guaranteed not to look. Verify the red state —
   do not infer it.
3. **Empty-glob guard — assert the message, not the exit code.** Point the globs at an empty
   directory and confirm the case fails *with the "nothing to lint" message*. Checking only that it
   went red is what lets the bug through: an unguarded version also exits non-zero — with
   `unbound variable` on bash 3.2, or ShellCheck's exit-3 usage dump on 5.x. Same distinction
   `lib.sh:18-25` draws about org access: an exit code is not an answer.
   **Run this under `/bin/bash` on macOS as well as under a 5.x bash.** The two failure modes differ
   by version, and a tester who sees `unbound variable`, reads it as "the guard fired," and ticks
   the box has verified nothing — which is the exact defect this item exists to catch.
4. **Multi-failure reporting.** Introduce violations in **two** files at once and confirm both are
   named. One file proves nothing about the `set -e` landmine above.
5. **Scope tamper-evidence — all four paths.** A gate that silently stops covering new files is
   the decay this check exists to prevent, and an assertion that passes vacuously is worse than
   none, so exercise each way it could:
   a. `git add -N .github/scripts/decoy.sh` — a tracked `.sh` outside the globs. Must be named, red.
   b. `git add -N scripts/decoy` — a tracked **extensionless** script opening `#!/usr/bin/env bash`,
      and a second one opening `#!/bin/bash -e` (a shebang carrying an argument). Both must be
      named, red. Keying on the `.sh` suffix alone lets these through the globs *and* the guard.
   c. Run the suite from a directory that is **not a git checkout**. It must FAIL with "scope is
      UNVERIFIED" — not print `ok all 0 tracked ... are covered` and ALL PASS.
   d. Confirm a zero-result lookup `fail`s **and** `finish`es, like the empty-glob guard: `fail()`
      only increments a counter, and the next line expands the array.
6. **Missing ShellCheck, local path:** run `bash template-tests/test_shellcheck.sh` directly with
   `shellcheck` renamed out of `PATH`. It must print one honest "shellcheck is not installed"
   failure and stop — **not** 24 lines of `FAIL <file>`. Item 5 does not cover this: the tool loop
   is a workflow step and never executes on this path.
7. **Wrong-cwd sanity:** `cd template-tests && bash test_shellcheck.sh` must still lint all 24
   files, by virtue of the `cd`.

## Rejected

- **A pre-commit hook (decided against for now).** `.pre-commit-config.yaml` says outright that its
  hooks are "SKIPPABLE with `git commit --no-verify` — the CI job is the real gate," and adding one
  makes ShellCheck a local install requirement for contributors. The CI case is the control; the
  hook would only be convenience. Cheap to add later if the feedback loop proves annoying.
- **`-S warning` (originally chosen; rejected on review).** The headroom argument below is real,
  but it bought insulation with the gate's own purpose. `SC2086` is `info` severity, so `-S warning`
  does not report unquoted expansion **at all** — demonstrated on a scratch file: `f="$1"; rm -rf $f`
  is reported at `-S style` and `-S info`, and vanishes at `warning`. A gate over scripts that run
  `rm -rf` and rewrite branch protection cannot exempt the defect class it was written to catch.
  Severity is now `-S info`.
- **`-S style`.** Still rejected, now for the original reason correctly scoped: `style` is the tier
  where new opinions get added between releases, so pinning there invites an unrelated PR to go red
  on an upgrade that changed no code here. `info` gets `SC2086` without that exposure. Measured on
  both versions in play — 0.9.0 and 0.11.0 — the tree is clean at `style` too, so this is a
  forward-looking choice, not a reaction to present noise.
- **`-x` / `--external-sources`.** Dropped after measuring, rather than carried as a harmless
  default. It resolves `# shellcheck source=` directives, and all **12 of 12** in this repo carry
  `disable=SC1091` — they explicitly suppress the only diagnostic it produces. (The original text
  added "and SC1091 is `note` severity, below the `-S warning` floor anyway." That second reason
  **died with the move to `-S info`**, where SC1091 is squarely in scope — and review was right that
  it was a non-sequitur even before then, since SC1091's severity says nothing about what `-x` buys.
  The directives now do the whole job, which is exactly why the two files that lacked them went red
  and had to be fixed. Note `-x` would **not** have saved them: without a `source=` directive
  ShellCheck cannot resolve a `${REPO_ROOT}`-interpolated path either.) And the flag that pulls
  *warnings* out of sourced files is `-a`/`--check-sourced`, not `-x`. So `-x` is a no-op today and
  stays one under those directives tomorrow. `-a` is not wanted either: `lib.sh` is itself in the
  glob and linted directly, so following it from each caller would re-report the same findings once
  per sourcing file.
- **A third-party ShellCheck action** (`ludeeus/action-shellcheck` and similar) — with the tradeoff
  stated honestly, because the obvious argument is self-contradictory. Rejecting the action for
  needing SHA-pinning and lockstep maintenance, in favour of a runner binary that is *unpinned,
  unrecorded, and rolls with the `ubuntu-latest` image on GitHub's schedule*, rejects a dependency
  for being unpinnable in favour of one we simply declined to pin — in a repo that pins actions to
  40-hex SHAs and has a test enforcing it. The honest version: the runner image is **already in this
  repo's trusted base** (every job depends on it for `bash`, `jq`, `gh`, `python3`), so ShellCheck
  adds no new trust boundary, while an action adds one for the same binary. We accept the
  consequence — a ShellCheck release can turn an unrelated PR red — and mitigate it by echoing
  `shellcheck --version` into the job output, so a mystery red is one glance to diagnose instead of
  a bisect.
- **Baselining the SC2034 instead of fixing it.** A baseline file is a permanent exception mechanism
  purchased to avoid writing two assertions. Worse here than usual: the finding is a real coverage
  gap (see above), so a baseline would freeze the defect in place under the appearance of a green
  gate.
- **Shipping the gate as payload.** Nothing to lint. See boundaries above.

## Out of scope

- **`actionlint` for the bash inside workflow `run:` blocks.** A real and acknowledged gap — the
  `sca.yml` scan step and `ci.yml` gate step are load-bearing shell that this gate cannot see. It is
  a separate tool, a separate supply-chain decision, and a separate spec.
- Linting the templates' `Makefile`s or `Dockerfile`.
- Any change to the 14 existing suites beyond the two `--yes` assertions in
  `test_apply_rulesets.sh`.
- **Pinning the ShellCheck version.** Still accepted as a consequence of using the runner's binary,
  but the risk is no longer hypothetical and this is now the weakest part of the design. Measured:
  `ubuntu-24.04` ships **0.9.0**, and 0.9.0 and 0.11.0 **disagree on this very tree** — 0.9.0
  reports two `SC2015` findings that 0.11.0 does not. Both are fixed, so the gate is green on both
  today, but a required check whose verdict depends on an unpinned binary is precisely what this
  repo SHA-pins every action to avoid. The version line in the output is the mitigation; a
  checksum-pinned download (the `gitleaks` / `osv-scanner` idiom already used here) is the fix, and
  is deferred to its own change rather than smuggled into this one.
- **Extending the gate into generated repos.** All 8 `scripts/*.sh` ship as payload but the gate
  does not go with them, so a generated repo never lints its own copies. Closing that means
  deciding what a generated repo's `ci` check should own — a larger question than this spec.
  Recorded here so it is a known gap rather than an unexamined one.
