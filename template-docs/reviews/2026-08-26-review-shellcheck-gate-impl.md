# Review record: the ShellCheck gate (implementation, PR #58)

Post-implementation review of `chore/shellcheck-gate`. Unlike the two spec rounds
(`2026-08-25-review-shellcheck-gate-spec.md`), this one changed **code**: five findings, all
resolved, plus four defects that resolving them exposed.

Every claim below was re-verified here before anything was edited — including the reviewer's own,
one of which did not survive. Findings are ranked as the reviewer ranked them.

The round has a single shape, and it is worth naming because it is the opposite of the spec
rounds' shape. The spec rounds found a control that was *unverified*. This round found a control
that was verified carefully and thoroughly — **against the wrong conditions**. The bash mechanics
were correct and could not be broken. What was wrong was the severity floor, the payload premise,
and the linter version every measurement was taken on. A measurement taken under conditions the
control does not actually run in is an assumption wearing a measurement's clothes.

---

## 1. MEDIUM-HIGH — `-S warning` exempted `SC2086`, the gate's headline defect class

`shellcheck -S warning` does not report `SC2086` (unquoted expansion — word splitting and globbing)
**at all**, because `SC2086` is `info` severity. Reproduced on a scratch file:

```
$ printf '#!/usr/bin/env bash\nf="$1"\nrm -rf $f\n' > sc2086.sh
$ shellcheck -S style sc2086.sh   → SC2086 reported, exit 1
$ shellcheck -S info  sc2086.sh   → SC2086 reported, exit 1
$ shellcheck -S warning sc2086.sh → no output,       exit 0
```

`scripts/` runs `rm -rf` and rewrites branch protection. A gate over that code cannot exempt
unquoted expansion, which is the first thing anyone would name if asked what ShellCheck is for.
The "headroom against future releases" argument traded the gate's stated purpose for insulation
against hypothetical noise.

**Resolved:** severity is `-S info` — the lowest floor that keeps `SC2086` without buying the
`style` tier's churn exposure. `-S style` remains rejected, now for the original reason correctly
scoped.

**But the reviewer's supporting claim was wrong**, and it mattered. The review argued the stricter
floor "costs literally nothing today," because `shellcheck -S style` over the tree exits 0 with no
output. True at 0.11.0. **False at 0.9.0, which is what CI runs** — see finding 5. At `-S info`,
0.9.0 reported two `SC2015` findings, so adopting the recommendation as written would have turned
the gate red on its first CI run. Both were fixed first; see "Defects this exposed" below.

## 2. MEDIUM — the "NOT payload" premise was false

`test_shellcheck.sh:15` (and the spec at `:63`, the plan at `:31` and `:192`, and the PR body)
claimed `init-repo.sh` deletes `scripts/`, so a generated repo has nothing to lint.

It does not. `init-repo.sh:359` is `rm -rf templates template-tests template-docs` — `scripts/` is
absent, and `:358` says so outright: *"scripts/ keeps apply-rulesets.sh regardless."*
`test_init_repo.sh:49-55` asserts `sca-gate.sh`, `bandit-gate.sh` and `ci-aggregate-gate.sh`
survive init. So **all 8 `scripts/*.sh` ship into every generated repo**, unlinted there, because
the gate lives in `template-tests/` and does not ship with them.

This inverts the argument. The comment was reassurance that the gate's blast radius is small; the
truth is that this repo is the **only** place 8 payload scripts are ever linted, which raises the
stakes on finding 1 rather than lowering them.

**Resolved:** corrected in all four places. The gate/payload asymmetry is now stated explicitly,
and "extend the gate into generated repos" is recorded in the spec's Out of scope as a known gap.

## 3. MEDIUM — the workflow tool-loop entry made diagnostics strictly worse

Adding `shellcheck` to `template-tests.yml`'s pre-flight loop meant a missing linter aborted **all
15 suites before any ran**. That discards the in-script guard (`test_shellcheck.sh:37-40`), which
is already correct and strictly better: one honest `FAIL`, and the other 14 suites still report.

The loop's own rationale is *"a suite that **dies** on a missing tool reports as a code failure."*
This suite does not die. The entry was insulation against a failure mode that cannot occur here.

**Resolved:** `shellcheck` removed from the loop; the loop is back to `jq gh python3 bash`, with a
comment recording why it is deliberately absent. The spec's "this needs **two** changes" decision
is now "this needs **one**."

## 4. LOW-MEDIUM — no tamper-evidence on scope

The globs are a decision, not a discovery, so a `.sh` added under `templates/` or `.github/scripts/`
would be silently never linted while the suite still printed `ALL PASS`. This repo already has an
idiom for exactly this decay — the lockstep assertion in `test_action_pins.sh`.

**Resolved:** the suite now asserts that every **tracked** `.sh` is inside the linted globs.
Tracked, not on-disk, is load-bearing: `git ls-files` cannot see `.claude/worktrees/` or
`templates/next/node_modules/`, which are precisely what the globs exist to exclude. Verified by
`git add -N .github/scripts/decoy.sh`, which produces:

```
  FAIL tracked .sh file(s) outside the linted globs — widen the scope above or exclude them deliberately:
         .github/scripts/decoy.sh
```

## 5. LOW (escalated) — an unverified version claim, on the PR's own headline risk

The plan stated *"ShellCheck 0.11.0 (preinstalled on `ubuntu-latest`)."* Verified against the
runner image manifest: `ubuntu-24.04` ships **`shellcheck 0.9.0-1`**. Every "measured/verified"
claim in the PR was produced at 0.11.0, on a laptop.

The reviewer rated this LOW on the grounds that they had checked 0.9.0 and it was clean. It is
clean — **at `-S warning`**. At the `-S info` floor finding 1 asks for, 0.9.0 and 0.11.0 disagree
on this tree, which is why this is recorded as the most consequential of the five rather than the
least. Downloaded 0.9.0 and ran it directly rather than trusting either account:

```
$ shellcheck-0.9.0 -S info scripts/*.sh template-tests/*.sh
scripts/apply-org-ruleset.sh:72:18: note: Note that A && B || C is not if-then-else. C may run when A is true. [SC2015]
scripts/apply-rulesets.sh:63:18:   note: Note that A && B || C is not if-then-else. C may run when A is true. [SC2015]
$ shellcheck-0.11.0 -S info scripts/*.sh template-tests/*.sh   → clean
```

**Resolved:** the version claim is corrected everywhere and framed as what it was — a local
measurement, not a runner fact. The gate is now verified green on **both** 0.9.0 and 0.11.0. The
spec's "pinning is out of scope" entry is rewritten to say the risk is demonstrated rather than
hypothetical, and to name the fix (a checksum-pinned download, the `gitleaks` / `osv-scanner`
idiom already used in this repo) while deferring it to its own change.

---

## Defects this exposed

Lowering the floor to `-S info` and re-measuring on 0.9.0 surfaced four real findings that
`-S warning` at 0.11.0 could not see. All are fixed rather than silenced — the same rule the spec
rounds set when `SC2034` turned out to be a missing assertion rather than dead code.

**Two `SC2015`, in `scripts/apply-rulesets.sh:63` and `scripts/apply-org-ruleset.sh:72.`** Both are
the org-plan guard:

```bash
[ -n "${PLAN}" ] && [ "${PLAN}" != "null" ] \
  || die "the ${ORG} plan came back empty — ..."
```

`lib.sh:36-37` already documents this exact hazard, so the repo had named the class and then
shipped two instances of it in the scripts that apply branch protection. In these two the
construct happens to be **safe** — `B` is a pure `[ ]` test that cannot fail for a non-logical
reason — so this is a true detection of a benign instance. Rewritten as the honest form anyway,
matching what `lib.sh` chose:

```bash
if [ -z "${PLAN}" ] || [ "${PLAN}" = "null" ]; then
  die "the ${ORG} plan came back empty — ..."
fi
```

Equivalent by De Morgan, and not left at that: both scripts were driven with a fake `gh` returning
an empty plan, and both still die with the correct message and exit 1.

**Two `SC1091`, in `test_contracts_docs.sh` and `test_init_repo.sh`.** These two source `lib.sh`
through `"${REPO_ROOT}/template-tests/lib.sh"` rather than the literal relative path, and so never
picked up the house `# shellcheck source=template-tests/lib.sh disable=SC1091` directive the other
13 files carry. Fixed by adding it.

Note **why the batched verification missed these**, because it is the same error as finding 5 in
miniature: `shellcheck scripts/*.sh template-tests/*.sh` passes `lib.sh` as an input, so ShellCheck
resolves the source and `SC1091` never fires. The gate runs **per file**, where it does. Verifying
a per-file gate with a batched command measures something the gate does not do. `-x` would not have
rescued them either: without a `source=` directive ShellCheck cannot resolve a `${REPO_ROOT}`
interpolation any more than it can guess.

---

## Verification

- `shellcheck -S info` over `scripts/*.sh template-tests/*.sh` exits 0 on **both** 0.9.0 and
  0.11.0; clean at `-S style` on both as well.
- `bash template-tests/test_shellcheck.sh` → `ALL PASS`, 25 `ok` lines (24 files + the scope
  assertion), under 0.11.0 and under 0.9.0 on `PATH`.
- All **15** suites `ALL PASS`.
- Scope guard fails correctly on an out-of-scope tracked `.sh` and returns to green when removed.
- Both rewritten org-plan guards die with the correct message and exit 1 under a fake `gh`.

## Not changed

- **Unlinted bash in workflow `run:` blocks.** Out of scope by the spec; `actionlint` is a separate
  decision. Unchanged by this round.
- **Pinning ShellCheck.** The case for it is materially stronger now that 0.9.0/0.11.0 divergence
  on this tree is a measured fact rather than a hypothesis, and the spec now says so. Deferred to
  its own change rather than expanded into this PR.

---

# Round two — review of the round-one fixes

All five round-one fixes were re-verified by the reviewer under **both** ShellCheck versions in
play (0.9.0 in a container, 0.11.0 locally) rather than taken from the write-up above, and all five
held. Six new findings, ranked as the reviewer ranked them.

Two of them are the same defect wearing different clothes, and it is the defect this document
already named once: **a control verified against the wrong conditions.** Round one's finding #4
added a scope assertion; round two found that the assertion could print `ok` over a scope it had
never actually read. The fix for a vacuous-pass finding reintroduced a vacuous pass.

## A. HIGH — the scope assertion discarded `git ls-files`' exit status

`git ls-files '*.sh' | grep -vxF ...` threw the lookup's status away inside a pipeline. Outside a
checkout, on `detected dubious ownership` (a uid mismatch inside a container), or on a locked
index, `git ls-files` writes nothing to stdout and exits 128 — which downstream is
indistinguishable from "there are no tracked files." Reproduced verbatim:

```
shellcheck: every tracked .sh file is in the linted set
fatal: not a git repository (or any of the parent directories): .git
  ok   all 0 tracked .sh files are covered by the globs
ALL PASS
```

That is precisely the failure mode the `nullglob` and empty-array guards fifteen lines above exist
to prevent, reintroduced by the fix for round one's #4. **Fixed:** the status is checked in an `if`,
and a failed lookup is a `fail`+`finish` reading *scope is UNVERIFIED, not clean* — the distinction
`lib.sh` already insists on ("a skipped check is NOT a passed check").

## B. MEDIUM-HIGH — nothing installed ShellCheck anywhere in the workflow

Round one's #3 backed the linter out of the pre-flight tool loop, and that reversal was correct on
diagnostics grounds — asserting there aborts all 15 suites before any runs. But it left **zero**
coverage: the gate rested entirely on `ubuntu-latest` happening to ship the binary. A runner-image
rotation that drops it turns a *required* check permanently red with no fix available inside this
repository. The spec defers *pinning*; it never addressed *installing*, and the two were being
conflated.

**Fixed:** a conditional install step in `template-tests.yml`. `command -v` short-circuits on
today's image, so the normal path is untouched, and the step deliberately does **not** `exit 1` on
a failed install — the missing-linter case still belongs to `test_shellcheck.sh`'s own guard, which
reports one honest FAIL and lets the other 14 suites run. Round one's diagnostics argument is
preserved intact; only the unfixable-from-inside-the-repo hole is closed.

## C. MEDIUM — tamper-evidence keyed on `*.sh`, so an extensionless script evaded it

`git ls-files '*.sh'` cannot see a tracked `scripts/foo` opening `#!/usr/bin/env bash`. Such a file
missed the globs *and* the guard, and the suite still printed ALL PASS. None exist today, which is
exactly what makes closing it free rather than a migration.

**Fixed:** membership is decided by shebang, not by suffix — `#!`…`sh` (sh, bash, dash, ksh, zsh)
plus the same line carrying an argument (`#!/bin/bash -e`). A `case` glob rather than `grep -E`,
because `\b` is a GNU extension and this suite runs against macOS's BSD grep too. Verified with
both probe shapes.

## D. LOW-MEDIUM — the plan's Global Constraints still carried the pre-implementation counts

The status banner declares Global Constraints "current and authoritative", and it said 46/23. The
shipped tree is **47/24** — confirmed on disk and in the index. **Fixed**, and the bullet now says
outright which numbers are the shipped ones, so the 46/23 surviving in the step bodies below it
reads as the historical record the banner says it is rather than as a contradiction. The spec's
measurement table and its two verification-item counts were stale for the same reason and were
corrected alongside.

## E. LOW — a line reference wrong at both ends

The spec cited `test_init_repo.sh:49-55` for the three surviving-script assertions. Line 49 is
`sca-policy.json` and 51-54 are a comment block; the assertions are at **50, 55 and 56**.
**Fixed.** Round one corrected this same paragraph's *premise* and left its *citation* wrong —
worth noting as a pattern, since a corrected claim with an uncorrected reference reads as verified.

## F. LOW — the referenced review record was untracked

The plan's status banner points at this file, and it had never been `git add`ed — the only written
record of round one was one `rm` from gone. **Fixed:** committed, alongside this round-two section.

## Confirmed sound, no change

- **The two `# shellcheck source=` additions are load-bearing, not cosmetic.** The reviewer
  independently confirmed that without them `SC1091` fires at `info` on the two files that source
  `lib.sh` through `${REPO_ROOT}`; the other 13 already carried the directive. The spec's Wiring
  row already describes them this way.
- **Round one's reversal of the pre-flight-loop finding.** The reasoning was re-checked and is
  right. Finding B above adds to it rather than overturning it.

## Verification

- All four scope-tamper paths exercised as probes and each one goes red: out-of-glob `.sh`,
  extensionless `#!/usr/bin/env bash`, `#!/bin/bash -e`, and running outside a git checkout.
- `bash template-tests/test_shellcheck.sh` → `ALL PASS`, 24 files plus the scope assertion.
- The workflow parses as YAML and the install step is a no-op wherever `shellcheck` is on `PATH`.
