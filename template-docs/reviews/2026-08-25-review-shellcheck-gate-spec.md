# Review record: `2026-08-25-shellcheck-gate-design.md` (spec, pre-implementation)

Documentation-only review record. No code changed. Every claim below was re-verified against the
repo before the spec was edited — the reviewer's numbers were checked, not taken on trust, and all
of them held exactly. Findings ranked most-severe first; **all are resolved in the spec**, which is
why this log exists rather than a follow-up list.

The three blocking findings share one shape: the spec argued that informal, unverified controls
lapse silently, and then specified a control that was itself unverified in three places. That is
worth recording, because the same failure is available to anyone writing the next gate here.

## 1. Blocking — the SC2034 is a missing assertion, not dead code

The spec's headline cost claim was "one line of deleted dead code," and the wiring table said to
delete `out_yes` at `template-tests/test_apply_rulesets.sh:60`.

Verified by reading 51–64: `out_yes` is the structural twin of `out_org` at line 51, minus the
assertions. The `--org` block checks the refusal message (56) and that nothing was applied (57);
the `--yes` block — guarding what line 61 itself calls "a consent bypass [that] must not exist" —
checks an exit code and stops. The variable is unread because someone stopped halfway.

So ShellCheck found a real coverage gap on its first enforced run, and the spec's response was to
delete the evidence — the baseline mechanism it rejects two sections later, cheaper to write and
harder to notice.

**Resolved:** new section "The single existing finding is a missing assertion, not dead code";
wiring row inverted to *add* the two assertions; cost claim in "Why this exists" corrected.
(Round one also left the earlier wording quoted in the spec for legibility; round-two finding E
removed that — see below.)

Assertion strings were taken from running the script, not invented. Note the regex differs from line
57's: that guards the *org* apply's messages, while `apply-rulesets.sh:149,153` log
`created new ruleset` / `updated existing ruleset` for the repo-level path. Copying 57 verbatim
would have asserted against strings this code path cannot emit — a vacuous check, inside the fix for
a vacuous check.

## 2. Blocking — the non-empty guard, as specified, could not fire

Bash does not enable `nullglob` by default, so a glob matching nothing expands to itself. Measured
in an empty directory under `bash`:

    files=(scripts/*.sh template-tests/*.sh)
    count=2
      [scripts/*.sh]
      [template-tests/*.sh]

A `[ ${#files[@]} -eq 0 ]` check therefore passes vacuously on two literal globs, which reach
ShellCheck as filenames: `openBinaryFile: does not exist`, exit 2.

The second-order defect is worse than the first. Testing plan item 3 said "point the globs at an
empty directory; the case must fail, not pass" — and it *does* fail, via the wrong path. The box
gets ticked and the guard ships having never once executed its own branch.

**Resolved:** the Decision now specifies `shopt -s nullglob` with the measurement inline, and
testing item 3 asserts on the *message* rather than the exit code, citing `lib.sh:18-25`'s "an exit
code is not an answer."

(Worth noting for future measurements: zsh errors on an unmatched glob instead of passing it
through, so this must be reproduced under `bash`. An interactive zsh check would have shown a
failure and suggested, wrongly, that the guard worked.)

## 3. Blocking — the `-S style` rejection was fabricated

The spec rejected stricter severities on the grounds that they "would churn the tree for no
correctness gain." Measured:

    shellcheck -S style -f gcc scripts/*.sh template-tests/*.sh
    template-tests/test_apply_rulesets.sh:60:4: warning: out_yes appears unused... [SC2034]

One finding. The same one. Clean at `style`, at `info`, and with `-x`. There was no churn.

`warning` is still the right tier, but for a different reason — headroom, since `style` is where
future ShellCheck releases add opinions, and pinning there invites an unrelated PR to go red on an
upgrade that changed no code here.

**Resolved:** claim deleted and the real argument stated. The boundaries bullet that carried the
same framing ("litigates formatting preferences across 3,663 lines") was corrected to match.
(Round one kept the retraction visible in the Rejected entry; round-two finding E moved that history
here — see below.)

## 4. The supply-chain argument was self-contradictory

`ludeeus/action-shellcheck` was rejected for needing SHA-pinning, Dependabot coverage, and lockstep
maintenance — in favour of the runner's ShellCheck, which is unpinned, unrecorded, and rolls with
the `ubuntu-latest` image on GitHub's schedule. That rejects a dependency for being unpinnable in
favour of one we declined to pin, in a repo that pins actions to 40-hex SHAs and tests that it did.

The conclusion survives; the reasoning did not.

**Resolved:** the entry now states the true argument — the runner image is already in this repo's
trusted base (`bash`, `jq`, `gh`, `python3` all come from it), so ShellCheck adds no new trust
boundary while an action adds one for the same binary — accepts the consequence that a ShellCheck
release can turn an unrelated PR red, and mitigates it by echoing `shellcheck --version` into the
job output. "Pinning the ShellCheck version" is now named in Out of scope rather than left implicit.

## 5. `set -e` would have truncated the per-file reporting

`lib.sh:3` is `set -euo pipefail` and it is sourced. A naked `shellcheck "$f"` in a `for` loop
aborts at the first offending file. Verified: a three-iteration loop with a failing command prints
one line and exits 1.

The spec argued for per-file reporting so a reader learns more than "shellcheck failed" — and the
obvious implementation would have produced exactly that opacity, by accident.

**Resolved:** named as landmine 1, pointing at `assert_ok` / explicit `if …; then pass; else fail; fi`,
and at `lib.sh:36-37`'s existing note on why `cmd && pass || fail` is not if-then-else (SC2015).
Testing item 4 now requires two simultaneous failures, since one file cannot detect this.

## 6. Minor — `-x` was unspecified

The spec cited the twelve `# shellcheck source=` directives as evidence of manual discipline, then
specified an invocation that ignores them: they do nothing without `-x`. Measured, `-x` and plain
output are byte-identical today.

**Resolved at the time** by choosing `-x` explicitly. **Superseded by round-two finding D:** that
rationale was itself unmeasured and wrong — all 12 directives carry `disable=SC1091`, SC1091 is
below the `-S warning` floor, and the flag for sourced-file warnings is `-a`, not `-x`. The flag is
now dropped.

## 7. Minor — the red-green test contradicted the glob decision

Testing item 2 said to introduce a violation "in a scratch copy." The explicit globs exist so
out-of-tree copies are never linted, making a scratch copy the one place the gate is guaranteed not
to look.

**Resolved:** red-green now requires editing a real file under `scripts/` or `template-tests/` and
reverting.

## Confirmed sound, no change

- **Riding the required `template-tests` context** instead of adding a status check. The
  PENDING-FOREVER argument is the real one. The review added a fact the spec had missed:
  `template-tests.yml:64` is `for t in template-tests/test_*.sh`, so the new case needs **no runner
  change** at all. Recorded in the wiring table.
- **Explicit globs over `find`** — understated, if anything. `find . -name '*.sh'` returns **46**
  files against **23** tracked: 22 in `.claude/worktrees/item-4-bandit-sast/` and one in
  `templates/next/node_modules/`. The spec had argued the worktree and did not know about
  `node_modules`. The measured table is now in the spec.
- Every opening statistic (3,663 lines, 23 files, 8 + 15, 12 `source=` directives, exactly one
  SC2034, zero `.sh` under `templates/`) re-verified exact.

---

# Round two — review of the revised spec

Round one's seven findings all confirmed closed by the reviewer. The revision then introduced three
new defects, plus one unmeasured rationale and one editorial problem. Same verification discipline:
every claim below was reproduced before the spec was touched, and all five held.

The pattern is worth naming because it repeated: **the spec kept writing checks its own standard had
to cash.** Round one's fabricated "churn" claim was replaced by a fresh unmeasured claim about `-x`
in a brand-new section. Measuring the alternative you reject is not a step you get to skip in a
document whose thesis is that unverified controls lapse.

## A. Blocking — the empty-glob guard died on `set -u` before it could report

`fail()` increments a counter; it does not exit. The Wiring row said "asserts the count is non-zero"
and never said the guard *stops*, so control reached the array expansion.

Under bash 3.2 — `/bin/bash` on every macOS machine, including the one a maintainer would verify
from — expanding an empty array under `set -u` is fatal. Reproduced on
`GNU bash, version 3.2.57(1)-release (arm64-apple-darwin24)`:

    count=0
    /bin/bash: line 1: f[@]: unbound variable

Fixed in bash 4.4, and `ubuntu-latest` runs 5.x, so **CI would never have shown it.** That inverts
the failure `template-tests.yml:42-46` already records ("It passed on my machine only because my git
happened to be configured"): green in CI, crash on the laptop.

The self-defeating part: testing item 3 existed to catch exactly this class, and as written it would
have died with `unbound variable` before reaching the message the tester was told to assert on.

**Resolved:** the Decision now requires `fail "…"; finish`, the Wiring row spells out the ordering,
and testing item 3 names both failure modes and requires running under `/bin/bash` *and* a 5.x bash
so `unbound variable` is not misread as the guard firing. Also recorded: zero-arg ShellCheck exits
**3** with a usage dump, not 1 — so even on modern bash the fall-through buried the message.

## B. Blocking — "a missing ShellCheck fails the run" was true only in CI

The Decision was implemented solely by adding `shellcheck` to the tool loop in
`template-tests.yml` — a workflow step. `bash template-tests/test_shellcheck.sh` never runs it.

And `set -e` is suppressed inside an `if` condition, so 127 flows into the `else` branch. Verified:

      FAIL fileA
      FAIL fileB
      FAIL fileC
    loop completed, set -e did not fire

A contributor without ShellCheck installed would get 23 lines of `FAIL <file>` and conclude their
bash was broken. Not fail-open — **fail-misattributed**, which costs more diagnostic time than the
honest skip the section forbids.

**Resolved:** the Decision is retitled "in BOTH entry points" and requires `command -v shellcheck` →
`fail` + `finish` inside the script; testing item 6 covers the local path, item 5 the CI path.

## C. Blocking — Wiring omitted the mandatory `cd`

For a design whose entire file-selection mechanism is *relative* globs, cwd is the precondition, not
an implementation detail. Without it the globs resolve against the caller's directory; combined with
A, `cd template-tests && bash test_shellcheck.sh` crashed with `unbound variable` rather than
reporting anything.

One correction to the review: the suites are **not** all identical. Eleven open with
`cd "$(dirname "$0")/.."` and source relatively; `test_init_repo.sh`, `test_link_vercel.sh`, and
`test_contracts_docs.sh` use `REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"` and source absolutely,
because they `cd` elsewhere later. The new case must use the **first** idiom.

**Resolved:** `cd` is first in the Wiring row, landmine 3 explains why the choice between the two
idioms is forced, and testing item 7 checks it from a wrong cwd.

## D. The `-x` rationale was invented — flag dropped

The claim was that `-x` keeps the twelve `# shellcheck source=` directives load-bearing. Three
independent refutations, one command each:

- **12 of 12** directives carry `disable=SC1091` — they suppress the only diagnostic `-x` resolves.
- SC1091 is `note` severity, below the `-S warning` floor. Verified against a scratch file pointing
  at a missing source: it reports at `-S info` and vanishes at `-S warning`.
- The flag that pulls *warnings* out of sourced files is `-a`/`--check-sourced`. `shellcheck --help`:
  `-x --external-sources  Allow 'source' outside of FILES`.

So `-x` was a no-op today and would stay one tomorrow.

**Resolved:** flag **dropped** rather than kept as a harmless default — carrying config whose only
defence is "it does nothing" is the cargo this spec complains about. The Rejected entry records all
three measurements, plus why `-a` is not wanted either: `lib.sh` is itself in the glob and linted
directly, so following it from each caller would re-report identical findings once per sourcing file.

## E. Editorial — draft archaeology stripped

Two sections narrated what an earlier draft had said. A design doc records the decision and its
evidence; the history belongs in this log.

**Resolved:** both retractions removed from the spec, measurements kept. This file is now the only
place round one's corrections are narrated.
