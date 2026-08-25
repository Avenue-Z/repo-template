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

Adoption cost is one line of deleted dead code.

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
- **It does not enforce style.** Severity is `warning`, not `style` or `info`. A correctness gate
  that also litigates formatting preferences across 3,663 lines earns its own bypass.
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

It must **not** be `find . -name '*.sh'`. A maintainer checkout can contain
`.claude/worktrees/<branch>/` — a complete stale copy of the repo, including its own
`template-tests/*.sh`. It is gitignored (`.gitignore:26`) and untracked, so it is harmless to git,
but a recursive walk would lint a months-old duplicate of this very suite. Best case that is
duplicate noise; worst case the gate goes red over code that is not in the repository and cannot be
fixed by changing the repository.

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

## Decision: the file list must be non-empty

Borrowed verbatim in spirit from `test_action_pins.sh`, which fails with "no remote actions found in
any workflow — this test is not testing anything." A gate that lints zero files passes trivially and
looks identical to a gate that lints everything. If both globs come back empty, that is a failure.

## Wiring

| File | Change |
|---|---|
| `template-tests/test_shellcheck.sh` | **New.** Sources `lib.sh`, globs both dirs, asserts non-empty, runs `shellcheck -S warning`, reports one `pass`/`fail` per file, ends with `finish`. |
| `.github/workflows/template-tests.yml` | Add `shellcheck` to the tool assertion list. |
| `template-tests/test_apply_rulesets.sh` | Remove the unused `out_yes` (line 60) — the single SC2034. |

Per-file reporting rather than one aggregate pass matters for the same reason `test_action_pins.sh`
names the offending SHA: a gate that says only "shellcheck failed" makes the reader re-run the tool
locally to learn anything.

## Testing

1. **Green:** the full suite passes 15/15 (14 existing + the new case).
2. **Red-green, not just green.** A gate that has never been observed failing is not known to work.
   Introduce a deliberate violation (an unquoted expansion in a scratch copy), confirm the suite
   goes red and names that file, then revert and confirm green. Verify the red state — do not infer
   it.
3. **Empty-glob guard:** confirmed by pointing the globs at an empty directory in a scratch copy;
   the case must fail, not pass.
4. **Tool assertion:** confirmed by running the workflow's tool loop with `shellcheck` renamed out
   of `PATH`; it must exit non-zero with the `::error::` line.

## Rejected

- **A pre-commit hook (decided against for now).** `.pre-commit-config.yaml` says outright that its
  hooks are "SKIPPABLE with `git commit --no-verify` — the CI job is the real gate," and adding one
  makes ShellCheck a local install requirement for contributors. The CI case is the control; the
  hook would only be convenience. Cheap to add later if the feedback loop proves annoying.
- **`-S style` or `-S info`.** Opinions, not defects. Would churn the tree for no correctness gain
  and invite the gate to be disabled wholesale.
- **A third-party ShellCheck action** (`ludeeus/action-shellcheck` and similar). It would need
  SHA-pinning, Dependabot coverage, and lockstep maintenance with `test_action_pins.sh` — real
  supply-chain surface — to run one binary that is already on the runner.
- **Baselining the SC2034 instead of fixing it.** A baseline file is a permanent exception mechanism
  purchased to avoid a one-line deletion. Fix it and start clean.
- **Shipping the gate as payload.** Nothing to lint. See boundaries above.

## Out of scope

- **`actionlint` for the bash inside workflow `run:` blocks.** A real and acknowledged gap — the
  `sca.yml` scan step and `ci.yml` gate step are load-bearing shell that this gate cannot see. It is
  a separate tool, a separate supply-chain decision, and a separate spec.
- Linting the templates' `Makefile`s or `Dockerfile`.
- Any change to the 14 existing suites beyond the one dead assignment.
