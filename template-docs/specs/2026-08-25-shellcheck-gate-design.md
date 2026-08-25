# ShellCheck gate for the template's own bash — design

## Why this exists

The template is **3,663 lines of bash across 23 files** — 8 in `scripts/`, 15 in `template-tests/`.
That bash is the machinery that creates every Avenue Z repo: it selects a stack, rewrites branch
lineage, resolves CODEOWNERS, applies rulesets, and links Vercel. Nothing lints it. Not in CI, not
in `.pre-commit-config.yaml`.

It is not unlinted because nobody cares. Twelve of those files carry `# shellcheck source=...`
directives, and at `-S warning` the entire tree produces **exactly one finding**
(`template-tests/test_apply_rulesets.sh:60`, SC2034 — `out_yes` assigned and never read). Someone
is running ShellCheck by hand and acting on it.

That is precisely the problem. This repo's stated posture is that no layer practices enforcement
theater and that "a failure to verify is never treated as a verified pass." An informal discipline
that lives in a maintainer's habits is the one control here that lapses silently — it survives
exactly as long as the person who remembers it. The gate is not being added because the code is
dirty; it is being added because the code is clean and nothing holds it there.

Adoption cost is **writing the two assertions the SC2034 is pointing at** — see the next section.
An earlier draft of this spec called it "one line of deleted dead code," which was wrong on both
counts.

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

- **It does not ship into generated repos.** `init-repo.sh` deletes `scripts/` and
  `template-tests/`, and there are **no `.sh` files anywhere under `templates/`** — the payload is
  Python and TypeScript. A gate shipped as payload would lint zero files in every repo created from
  here. This is template-only machinery, exactly like `template-tests.yml` itself.
- **It does not reason across files.** ShellCheck is single-file static analysis. It cannot know
  that `apply-rulesets.sh` sends a malformed ruleset payload, that a `gh api` call queries the wrong
  field, or that a guard fails open. That is what the 14 behavioural suites are for. This gate
  catches the class below that: unquoted expansions, unreachable branches, misused test operators,
  dead assignments.
- **It does not enforce style.** Severity is `warning`, not `style` or `info` — though not because
  the stricter tiers would be noisy here. Measured, they report the same single finding. The reason
  is headroom against future ShellCheck releases; see Rejected.
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
| `git ls-files '*.sh'` — what is actually in the repo | **23** |
| `find . -name '*.sh'` | **46** |
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

## Decision: a missing ShellCheck fails the run, never skips it

`lib.sh` states it directly: "A skipped check is NOT a passed check, and must never read like one."
A linter that isn't installed has verified nothing, and reporting green on that basis is the exact
fail-open pathology `sca.yml` refuses ("refusing to report a clean check").

So `shellcheck` joins the tool assertion already at the top of `template-tests.yml`:

```yaml
for t in jq gh python3 bash; do
```

ShellCheck is preinstalled on `ubuntu-latest`, but that file's own comment argues the point —
"assert it rather than assume — a suite that dies on a missing tool reports as a code failure."

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

(Note for anyone reproducing the measurement interactively: zsh errors on an unmatched glob rather
than passing it through, so this must be checked under `bash`, which is what the suite and CI run.)

## Wiring

| File | Change |
|---|---|
| `template-tests/test_shellcheck.sh` | **New.** Sources `lib.sh`, sets `nullglob`, globs both dirs, asserts the count is non-zero, echoes `shellcheck --version`, runs `shellcheck -x -S warning`, reports one `pass`/`fail` per file, ends with `finish`. |
| `.github/workflows/template-tests.yml` | Add `shellcheck` to the tool assertion list. **No runner change** — line 64 is `for t in template-tests/test_*.sh`, so the new case is discovered automatically. |
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
2. **`nullglob`**, per the Decision above.
3. **`-x` is a deliberate choice, not a default.** Twelve files carry `# shellcheck source=`
   directives, and those do nothing unless ShellCheck is invoked with `-x`. Measured today, `-x` and
   plain produce byte-identical output — so this changes nothing now, and is chosen so the existing
   directives are load-bearing rather than cargo the next time someone adds a `source` line.

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
   went red is what lets the `nullglob` bug through: the unfixed version also exits non-zero, via
   `openBinaryFile: does not exist`. Same distinction `lib.sh:18-25` draws about org access — an
   exit code is not an answer.
4. **Multi-failure reporting.** Introduce violations in **two** files at once and confirm both are
   named. One file proves nothing about the `set -e` landmine above.
5. **Tool assertion:** confirmed by running the workflow's tool loop with `shellcheck` renamed out
   of `PATH`; it must exit non-zero with the `::error::` line.

## Rejected

- **A pre-commit hook (decided against for now).** `.pre-commit-config.yaml` says outright that its
  hooks are "SKIPPABLE with `git commit --no-verify` — the CI job is the real gate," and adding one
  makes ShellCheck a local install requirement for contributors. The CI case is the control; the
  hook would only be convenience. Cheap to add later if the feedback loop proves annoying.
- **`-S style` / `-S info` (chosen against, but not for the reason you might assume).** An earlier
  draft claimed these would "churn the tree." That was fabricated, and measuring it takes one
  command: at `style` and at `info` the tree produces **the same single SC2034** and nothing else.
  There is no churn to avoid. The real argument for sitting at `warning` is *headroom*: severity is
  the contract with future ShellCheck releases, and `style` is the tier where new opinions get
  added, so pinning there invites an unrelated PR to go red on an upgrade that changed no code here.
  A spec that opens by measuring the tree does not get to skip measuring the alternative it rejects.
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
- **Pinning the ShellCheck version.** Accepted as a consequence of using the runner's binary; see
  Rejected. If a release ever does turn an unrelated PR red, revisit with the version line already
  in the output.
