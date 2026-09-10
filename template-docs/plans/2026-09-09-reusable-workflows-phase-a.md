# Reusable Workflows — Phase A Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn `repo-template`'s `checks.yml` into a callable reusable workflow, publish it behind a
moving `v1` tag, and gate that tag on the template's own test suite — so that a fix landed here reaches
all 11 derived repos with no PR anywhere.

**Architecture:** `checks.yml` gains `workflow_call` alongside its existing `pull_request` and
`schedule` triggers, so it is simultaneously a consumable and this repo's own live gate. The three gate
scripts are staged into `RUNNER_TEMP` from the template at the ref the workflow was *called* at
(`github.job_workflow_ref`), except in `repo-template` itself, where they come from the workspace. A
checked-in golden file plus a test suite (the "tripwire") makes any movement of the consumer-visible
surface a failing test, and a `workflow_run`-triggered workflow advances `v1` only when the tripwire is
quiet.

**Tech Stack:** GitHub Actions (`workflow_call`, `workflow_run`, `job_workflow_ref`), bash 3.2+, `jq`,
`python3` + `PyYAML` (test-side workflow parsing), GitHub rulesets via `gh api`.

**Spec:** `template-docs/specs/2026-09-09-reusable-workflows-design.md`

**Scope:** Phase A only — everything inside `repo-template`, plus the companion marketplace PR
(Task 9) and the manual tag cut (Task 10). Phases B–H (the pilot, the nine consumer migrations, and
`python-ci.yml`) are separate plans and cannot be written concretely until Phase B answers the three
Step 0 OPEN mechanics.

---

## Global Constraints

Copied verbatim from the spec. Every task's requirements implicitly include this section.

- **Branch flow:** `feat/* | fix/* | docs/* | chore/* | ci/* | dependabot/* → dev → staging → main`.
  **Never push directly to `main`.** This plan's work lands on one branch, one PR, targeting `dev`.
- **The job key must stay literally `checks`.** Under §1 clause 1 it is the single most expensive
  string in the design: the consumer context is `<caller-job> / <called-job>`, so renaming either half
  renames the check, and a required check that no longer reports does not fail a PR — it hangs it
  PENDING FOREVER.
- **The consumer-facing context is `checks / checks`.** Pick it once and never change it.
- **`checks.yml` needs no secrets** and must stay `permissions: contents: read`. Callers need no
  `secrets: inherit`. The only elevated permission anywhere in this plan is `contents: write` on the
  advance workflow, and it exists solely to move a tag.
- **Every remote action is pinned to a full 40-hex commit SHA with a `# vX.Y.Z` comment.**
  `test_action_pins.sh` fails on a bare tag and on any core/template SHA mismatch. The pin in use is
  `actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1` — reuse that exact string.
- **`template-tests` must never be red at a phase boundary.** §4 gates the `v1` advance on it, so
  Tasks 1–8 land as one PR: the workflow change and the assertions it falsifies cannot be separated.
- **A skipped check is not a passed check** (`template-tests/lib.sh:9-11`), and "I could not tell" is
  never "nothing is wrong" (`apply-rulesets.sh:53-62`). Every refusal path in this plan exits non-zero
  and says why.
- **Template-only artifacts must not ship.** `init-repo.sh` deletes `templates/`, `template-tests/`,
  `template-docs/` and `.github/workflows/template-tests.yml`. Anything new that belongs to the
  template rather than to a generated repo has to be added to that cull explicitly.
- **Template design docs live in `template-docs/`**, never `docs/superpowers/{specs,plans}/` —
  `test_init_repo.sh:68-73` fails on a dated `.md` left in the latter.
- **Billing:** Actions is billing-blocked org-wide. Tasks 1–8 are verified entirely on a laptop by
  `template-tests/`. Tasks 6, 7, and 10 have a CI-only half that cannot be observed until billing is
  restored; each says so at the point of use.

### Two requirements derived here, not stated in the spec

Both are consequences of Phase A that the design did not follow through. Flagged so a reviewer can
reject them on their merits rather than absorb them silently.

1. **`.github/workflows/advance-v1.yml` and `.github/reusable-contract.json` would ship to generated
   repos.** `init-repo.sh:371` removes only `template-tests.yml`. A generated repo carrying a workflow
   that force-moves a `v1` tag is a defect. Task 7 extends the cull and Task 5 asserts it.
2. **The verdict step must take its script from `RUNNER_TEMP` on every event, not only on
   `pull_request`.** Today `checks.yml:254-258` falls back to the workspace copy on non-PR events. In a
   consumer that copy is deleted by Phase E's cleanup, so the weekly scheduled audit would break some
   months after this plan lands, in a repo nobody is looking at. Task 3 removes the fallback.

---

## File Structure

**Modified**

| File | Responsibility after this plan |
|---|---|
| `.github/workflows/checks.yml` | Dual-role gate: `workflow_call` for consumers, `pull_request` + `schedule` for this repo. Owns the script-staging split. |
| `.github/workflows/template-tests.yml` | Runs the bash suite, **and** carries the layer-2 self-call job that proves `checks.yml` is callable. |
| `.github/rulesets/repo-ruleset.json` | Branch rules only. No longer names any status-check context. |
| `scripts/apply-rulesets.sh` | Decides *which* `checks` context to require, from the local `checks.yml`. |
| `scripts/check-base-branch.sh` | Nine-prefix matrix; its error message is the authoritative statement of that matrix. |
| `scripts/init-repo.sh` | Writes a caller workflow instead of copying `checks.yml`; culls the new template-only artifacts. |
| `CONTRIBUTING.md`, `SECURITY.md`, `docs/ADOPTION.md` | Matrix defers to the guard's output; `.github/` code-ownership; marketplace-companion rule. |

**Created**

| File | Responsibility |
|---|---|
| `.github/reusable-contract.json` | The golden consumer-visible surface. Editing it is the deliberate "this is a version bump" decision. |
| `.github/workflows/advance-v1.yml` | Moves `v1` and cuts the next point tag, gated on the tripwire. Template-only. |
| `template-tests/test_reusable_contract.sh` | Layer 3. Asserts `checks.yml` against the golden. |
| `template-tests/test_advance_v1.sh` | Drives the advance workflow's decision block against real temp git repos. |

**Not changed, but read before you touch its neighbours:** `template-tests/test_checks_verdict.sh`
(Task 3 adds one case), `scripts/ci-aggregate-gate.sh`, `scripts/sca-gate.sh`.

---

### Task 1: The nine-prefix branch matrix

The smallest self-contained change, and it has no dependency on the workflow split. Do it first so the
branch opens with a green suite.

**Files:**
- Modify: `scripts/check-base-branch.sh:17-27`
- Modify: `CONTRIBUTING.md:5`, `CONTRIBUTING.md:20-21`
- Test: `template-tests/test_guard_matrix.sh:25-39`

**Interfaces:**
- Consumes: nothing.
- Produces: `check-base-branch.sh <head_ref> <base_ref>` — unchanged signature, exit 0 on a conforming
  pair, exit 1 otherwise. Task 3 invokes it from `${RUNNER_TEMP}/trusted-scripts/`.

- [ ] **Step 1: Write the failing tests**

Add to `template-tests/test_guard_matrix.sh`, immediately after the existing `assert_pass staging main`
line (currently `:32`):

```bash
# The three prefixes added when the matrix became org-wide (spec §1). perf/ has 2 real uses in the
# fleet; refactor/ and test/ are conventional-commit types added pre-emptively, on the reasoning that
# a contributor who reaches for a legitimate type and is refused learns the guard is arbitrary rather
# than that their branch is wrong.
assert_pass perf/x dev
assert_pass refactor/x dev
assert_pass test/x dev
```

And after the existing `assert_fail randomname dev` (currently `:39`):

```bash
# The three deliberate exclusions (spec §1 and Rejected). Each was wanted at some point.
assert_fail security/x dev     # a dep bump is fix(deps): -> fix/. The guard was right.
assert_fail feature/x dev      # the most common near-miss; must be REJECTED, not accepted
assert_fail revert/x dev       # GitHub's Revert button generates revert-<PR#>-<branch>, with a HYPHEN
assert_fail revert-42-feat/x dev

echo "guard-base-branch: the error message names the correction for the common near-miss"
# The single most common near-miss is feature/ (6 branches in the fleet). Rejecting it silently and
# rejecting it with "use feat/, not feature/" cost the same to implement and differ entirely in
# whether the contributor's next push succeeds.
msg="$("$SCRIPT" feature/x dev 2>&1 || true)"
assert_match "the guard names feat/ when it rejects feature/" 'use feat/, not feature/' "$msg"
# Once the script is central, scripts/check-base-branch.sh does not exist in the contributor's repo.
# Telling them to edit a path they cannot see, in the moment they are already confused, is worse than
# saying nothing. The message must point at a PR against the template instead.
assert_nomatch "the guard no longer tells a consumer to edit a file they do not have" \
  'case statement in scripts/check-base-branch\.sh' "$msg"
assert_match "the guard points at a PR against the template" 'Avenue-Z/repo-template' "$msg"
assert_match "the guard's own output lists the full matrix" \
  'perf/.*refactor/.*test/' "$msg"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash template-tests/test_guard_matrix.sh`
Expected: FAIL — `perf/x -> dev should PASS`, `feature/x -> dev should FAIL` passes already but the
four message assertions fail, ending in `N FAILURE(S)` and exit 1.

- [ ] **Step 3: Widen the matrix and rewrite the error message**

Replace `scripts/check-base-branch.sh:17-27` with:

```bash
case "$head_ref" in
  feat/*|fix/*|docs/*|chore/*|ci/*|dependabot/*|perf/*|refactor/*|test/*) want=dev ;;
  dev)                                                                    want=staging ;;
  staging)                                                                want=main ;;
  *)
    echo "::error::Unrecognized branch prefix '${head_ref}'. This guard FAILS CLOSED."
    echo "Allowed: feat/ fix/ docs/ chore/ ci/ dependabot/ perf/ refactor/ test/ — or dev, staging."
    # THIS OUTPUT IS THE AUTHORITATIVE STATEMENT OF THE MATRIX. The script is central now: it is
    # staged from the template, and the repo the contributor is standing in does not contain it.
    # Each generated repo's CONTRIBUTING.md is a copy that drifts from this list the first time a
    # prefix is added, so the copies defer to this message rather than restating it.
    case "$head_ref" in
      feature/*)  echo "Did you mean 'feat/'? Use feat/, not feature/ — it is the conventional-commit type." ;;
      revert*)    echo "Reverts are done manually, as fix/ branches. There is deliberately no revert prefix." ;;
      security/*) echo "A security fix is still a fix/ branch (a dependency bump is fix(deps):, so fix/)." ;;
    esac
    echo "Need a new prefix? Open a PR against Avenue-Z/repo-template — this guard is shared by every repo."
    exit 1
    ;;
esac
```

Update the header comment at `:4-9` to list the nine prefixes so the file does not contradict itself.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash template-tests/test_guard_matrix.sh`
Expected: `ALL PASS`.

- [ ] **Step 5: Update `CONTRIBUTING.md` to defer rather than restate**

Replace `CONTRIBUTING.md:5` with:

```text
    feat/* | fix/* | docs/* | chore/* | ci/* | dependabot/* | perf/* | refactor/* | test/*  →  dev  →  staging  →  main
```

Replace `CONTRIBUTING.md:20-21` with:

```markdown
unrecognized branch prefix**. The matrix is enforced centrally and the guard's own error output is its
authoritative statement — if this list and that message ever disagree, the message is right. Need a new
prefix? Open a PR against `Avenue-Z/repo-template`.
```

- [ ] **Step 6: Run the whole suite and lint**

Run: `shellcheck scripts/check-base-branch.sh && for t in template-tests/test_*.sh; do bash "$t" >/dev/null || echo "FAIL $t"; done; echo done`
Expected: no `FAIL` lines. `test_shellcheck.sh` lints `scripts/` and `template-tests/`, so a
ShellCheck finding here fails the suite, not just the linter.

- [ ] **Step 7: Commit**

```bash
git add scripts/check-base-branch.sh CONTRIBUTING.md template-tests/test_guard_matrix.sh
git commit -m "feat: widen the base-branch matrix to nine prefixes and centralise its statement"
```

---

### Task 2: The golden contract and the tripwire

Layer 3 of §4. This task also lands the dual triggers, because the tripwire's whole subject is the
`on:` block and a tripwire written against the old shape is a test of nothing.

**Files:**
- Create: `.github/reusable-contract.json`
- Create: `template-tests/test_reusable_contract.sh`
- Modify: `.github/workflows/checks.yml:18-46` (the `on:` block)

**Interfaces:**
- Consumes: nothing.
- Produces: `.github/reusable-contract.json`, whose fields are `job` (string), `on` (sorted array of
  trigger names), `inputs` (sorted array), `secrets` (sorted array). Task 7's advance workflow diffs
  this exact path; Task 5 asserts it does not ship.

- [ ] **Step 1: Write the golden file**

Create `.github/reusable-contract.json`:

```json
{
  "_comment": "THE CONSUMER-VISIBLE SURFACE OF checks.yml. Editing this file is the deliberate decision that the surface moved. template-tests/test_reusable_contract.sh asserts checks.yml matches it exactly, and .github/workflows/advance-v1.yml REFUSES to advance the v1 tag while this file differs from what v1 points at. See template-docs/specs/2026-09-09-reusable-workflows-design.md sections 1 and 4.",
  "job": "checks",
  "on": ["pull_request", "schedule", "workflow_call"],
  "inputs": [],
  "secrets": []
}
```

- [ ] **Step 2: Write the failing tripwire suite**

Create `template-tests/test_reusable_contract.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=template-tests/lib.sh disable=SC1091
source template-tests/lib.sh

WORKFLOW=.github/workflows/checks.yml
GOLDEN=.github/reusable-contract.json

# LAYER 3 OF THE v1 GATE (spec §4). Eleven repos execute this workflow as their only security gate,
# and v1 advances automatically. This suite does NOT know whether a change is breaking. It knows the
# consumer-visible surface MOVED, and forces a human to say which it is — the same job the ShellCheck
# gate does for lint discipline: convert a rule that lives in one maintainer's head into a red test.
#
# The three things a consumer can observe are the job key (it IS the context, as `<caller>/<called>`),
# the triggers, and the declared inputs/secrets. Nothing else here is a contract.

echo "reusable contract: the golden file and the workflow both exist"
assert_file "the golden contract file exists" "$GOLDEN"
assert_file "the workflow exists" "$WORKFLOW"

actual="$(python3 - "$WORKFLOW" <<'PY'
import json, sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
# PyYAML resolves an unquoted `on:` key to the BOOLEAN True (the YAML 1.1 y/n/on/off rule). Reading
# d['on'] therefore returns None on a perfectly valid workflow, and every trigger assertion below
# would pass vacuously against an empty list. Accept either key.
on = d.get('on', d.get(True)) or {}
jobs = list(d.get('jobs', {}))
call = (on.get('workflow_call') or {}) if isinstance(on, dict) else {}
print(json.dumps({
    "job": jobs[0] if len(jobs) == 1 else "|".join(jobs),
    "on": sorted(on) if isinstance(on, dict) else sorted(on if isinstance(on, list) else [on]),
    "inputs": sorted((call.get('inputs') or {})),
    "secrets": sorted((call.get('secrets') or {})),
}, sort_keys=True))
PY
)"
expected="$(jq -Sc 'del(._comment)' "$GOLDEN")"

echo "reusable contract: checks.yml matches the golden EXACTLY (additions included, not just removals)"
assert_eq "$expected" "$actual" "the consumer-visible surface of checks.yml == .github/reusable-contract.json"

# Spelled out separately so a failure names the thing that broke rather than printing two JSON blobs.
echo "reusable contract: the three properties, individually"
assert_eq "checks" "$(jq -r '.job' <<<"$actual")" "the job key is literally 'checks' (it IS the context)"
assert_match "on: declares workflow_call (consumers call it)"  'workflow_call'  "$(jq -r '.on|join(" ")' <<<"$actual")"
# This is the assertion that catches the silent-failure path a second time, from a different angle:
# if someone strips pull_request while tidying checks.yml into a "pure" reusable workflow, every
# newly generated repo ships a workflow with no triggers that enforces nothing and reports nothing.
assert_match "on: still declares pull_request (it guards repo-template itself)" 'pull_request' "$(jq -r '.on|join(" ")' <<<"$actual")"
assert_match "on: still declares the weekly audit"             'schedule'       "$(jq -r '.on|join(" ")' <<<"$actual")"

finish
```

- [ ] **Step 3: Run it to verify it fails**

Run: `bash template-tests/test_reusable_contract.sh`
Expected: FAIL on the exact-match assertion — `checks.yml` has no `workflow_call` yet, so `actual`
carries `["pull_request","schedule"]` against the golden's three.

- [ ] **Step 4: Add `workflow_call` to `checks.yml`**

Insert into `.github/workflows/checks.yml` immediately after `on:` (currently `:18`), before the
`pull_request` comment block:

```yaml
  # CONSUMERS CALL THIS. `workflow_call` alongside `pull_request` is the standard shape for a workflow
  # that is both a consumable and a live gate in its own repo, and both halves are load-bearing:
  #
  #   without workflow_call  -> the 11 derived repos cannot reach this file at all and stay frozen.
  #   without pull_request   -> init-repo.sh's generated repos would ship a workflow with NO TRIGGERS.
  #                             It would never run, enforce nothing, emit no annotation, and appear in
  #                             the Actions tab as a workflow with no runs. Silent, total, and green.
  #
  # It also keeps THIS repo's own context literally `checks`: pull_request runs are ordinary top-level
  # jobs, not calls, so only consumers see the renamed `checks / checks`. scripts/apply-rulesets.sh
  # decides which of the two to require, from this very block.
  #
  # No inputs and no secrets, deliberately. Adding either moves the consumer-visible surface —
  # .github/reusable-contract.json is the golden and template-tests/test_reusable_contract.sh is the
  # tripwire. See the spec, §1 and §4.
  workflow_call:

```

- [ ] **Step 5: Run it to verify it passes**

Run: `bash template-tests/test_reusable_contract.sh`
Expected: `ALL PASS`.

- [ ] **Step 6: Run the whole suite**

Run: `for t in template-tests/test_*.sh; do bash "$t" >/dev/null || echo "FAIL $t"; done; echo done`
Expected: no `FAIL` lines. In particular `test_checks_verdict.sh` still parses the workflow — it
reads `d['jobs']['checks']['steps']`, which this change does not touch.

- [ ] **Step 7: Commit**

```bash
git add .github/reusable-contract.json .github/workflows/checks.yml template-tests/test_reusable_contract.sh
git commit -m "feat: declare workflow_call on checks.yml and pin its surface with a golden tripwire"
```

---

### Task 3: The staging split

The core of §2. The gate scripts stop coming from the caller's base branch and start coming from the
template at the ref this workflow was called at — except in `repo-template` itself.

**Files:**
- Modify: `.github/workflows/checks.yml:56-126` (the checkout/staging steps) and `:241-262` (verdict)
- Modify: `template-tests/test_guard_matrix.sh:41-56`
- Modify: `template-tests/test_sca.sh:145`, `template-tests/test_sca.sh:157`
- Modify: `template-tests/test_checks_verdict.sh` (one added case)

**Interfaces:**
- Consumes: `check-base-branch.sh` from Task 1.
- Produces: three scripts staged at `${RUNNER_TEMP}/trusted-scripts/` —
  `check-base-branch.sh`, `sca-gate.sh`, `ci-aggregate-gate.sh` — on **every** event, in both the
  local and the called path. Every later reference in `checks.yml` uses that directory.

- [ ] **Step 1: Write the failing tests**

In `template-tests/test_guard_matrix.sh`, replace the block at `:41-56` (from the
`echo "guard-base-branch: the guard's logic must come from the BASE branch..."` line through the
`assert_match "declares a read-only permissions block"` line) with:

```bash
echo "guard-base-branch: the guard's logic must not be supplied by the PR it judges"
# The workflow runs on pull_request, so a default checkout gives it the PR HEAD's tree — which means
# the PR supplies the very script that judges it. A PR from wip/x -> main that also rewrote
# check-base-branch.sh to `exit 0` would pass its own guard, and with
# required_approving_review_count: 0 nobody has to look at it.
#
# The base-branch checkout that used to close this is GONE: on the consumer path there is no base
# branch worth trusting, and the scripts now come from the TEMPLATE at the ref this workflow was
# called at. See the spec, §2.
wf="$(cat "$WORKFLOW")"
# job_workflow_ref, NOT workflow_ref. The latter is the CALLER's workflow and resolving the scripts
# from it would stage a consumer's own tree. The former is this called workflow's ref path, e.g.
# Avenue-Z/repo-template/.github/workflows/checks.yml@refs/tags/v1.2.0 — which is also what makes the
# immutable point tags an actual rollback rather than a rollback of the YAML only.
assert_match "the script ref comes from github.job_workflow_ref" 'github\.job_workflow_ref' "$wf"
assert_nomatch "the script ref is NOT taken from github.workflow_ref (that is the caller's)" \
  'github\.workflow_ref' "$wf"
# A hardcoded tag would defeat the point tags exactly as silently: checks.yml@v1.2.0 would execute
# scripts staged from the moving v1.
assert_nomatch "the template checkout does not hardcode a tag" 'ref: *v1 *$' "$wf"
# repo-template's own PRs take the workspace copy instead, so a PR that CHANGES a gate script is
# exercised by the run reviewing it, and so that Phase A's first PR is not red on a tag Phase A
# exists to cut.
assert_match "the staging step branches on the caller's repository" 'Avenue-Z/repo-template' "$wf"
assert_match "declares a read-only permissions block" 'contents: *read' "$wf"
```

In `template-tests/test_sca.sh`, replace the line at `:145`:

```bash
assert_match "checks.yml runs sca-gate.sh from the trusted staging directory" \
  'trusted-scripts/sca-gate\.sh' "$wf"
```

...and replace the `rm -rf .trusted-base` assertion at `:157` (keep the comment above it, which is
still exactly the reason) with:

```bash
# The name of the directory is not the property worth asserting; the ORDER is. Assert that the
# staging directory is deleted, and that the deletion appears BEFORE the first scanner step.
assert_match "the template checkout is removed from the workspace" 'rm -rf \.trusted-template' "$wf"
rm_line="$(grep -n 'rm -rf \.trusted-template' "$WF" | head -1 | cut -d: -f1)"
scan_line="$(grep -n 'osv-scanner scan' "$WF" | head -1 | cut -d: -f1)"
if [ -n "$rm_line" ] && [ -n "$scan_line" ] && [ "$rm_line" -lt "$scan_line" ]; then
  pass "the staging directory is deleted BEFORE osv-scanner walks the workspace"
else
  fail "rm -rf .trusted-template (line ${rm_line:-none}) must come before osv-scanner (line ${scan_line:-none}) — otherwise a PR that FIXES a vulnerable dependency still fails on the staged copy's manifests"
fi
```

In `template-tests/test_checks_verdict.sh`, replace the final block (from
`echo "checks verdict: a PR with no trusted verdict script must refuse, not fall back"` to `finish`)
with:

```bash
# The verdict logic MUST come from the trusted staging directory on EVERY event. If it came from the
# workspace, a PR could rewrite ci-aggregate-gate.sh to `exit 0` and switch off the guard, the secret
# scan and the SCA gate in one line. And the workspace copy is not a safe fallback in a CONSUMER
# either: Phase E's cleanup deletes it, so a workspace fallback would break the weekly scheduled audit
# months later, in a repo nobody is watching. A missing trusted copy must refuse to report a verdict.
echo "checks verdict: a missing trusted verdict script must refuse on every event, never fall back"
rm -f "${RT}/trusted-scripts/ci-aggregate-gate.sh"
verdict "trusted verdict script missing on a PR -> BLOCKED"       1 pull_request success success success
verdict "trusted verdict script missing on the audit -> BLOCKED"  1 schedule    skipped success success

finish
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash template-tests/test_guard_matrix.sh; bash template-tests/test_sca.sh; bash template-tests/test_checks_verdict.sh`
Expected: all three end in `N FAILURE(S)`. `test_guard_matrix.sh` fails on `job_workflow_ref`;
`test_sca.sh` fails on `trusted-scripts/sca-gate.sh` and `rm -rf .trusted-template`;
`test_checks_verdict.sh` fails the schedule case, because today's verdict step falls back to
`scripts/ci-aggregate-gate.sh` on a non-PR event and that file exists in the checkout.

- [ ] **Step 3: Replace the checkout and staging steps**

In `.github/workflows/checks.yml`, replace everything from `- name: Checkout the base branch` through
the end of the `Stage the trusted scripts outside the workspace` step (currently `:60-99`), **and**
delete the later `- name: Checkout the tree under review` step (currently `:119-126`), with this block
placed first inside `steps:`:

```yaml
      # ---------------------------------------------------------------- the tree under review
      # First, because everything below either scans it or stages alongside it. fetch-depth: 0 for two
      # reasons, both inherited from secret-scan.yml: the audit path scans all of history, and the PR
      # path needs origin/<base> present locally to diff against.
      - name: Checkout the tree under review
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          fetch-depth: 0

      # ---------------------------------------------------------------- trusted scripts
      # WHERE THE GATE SCRIPTS COME FROM, AND WHY IT IS NOT THE WORKSPACE.
      #
      # These three scripts make every decision this job reports. If they came from the PR's own tree,
      # a PR could rewrite one to `exit 0` and neuter the guard, the secret scan and the SCA gate in
      # one line — and with required_approving_review_count: 0 nobody has to look.
      #
      # TWO PATHS, because one size is wrong for both populations:
      #
      #   a CONSUMER -> the template, at the ref THIS WORKFLOW WAS CALLED AT. That is
      #                 github.job_workflow_ref (e.g. Avenue-Z/repo-template/.github/workflows/
      #                 checks.yml@refs/tags/v1.2.0), NOT github.workflow_ref, which is the CALLER's
      #                 workflow and would stage the consumer's own tree straight back into the job.
      #                 Deriving it rather than hardcoding `ref: v1` is what makes the immutable point
      #                 tags a real rollback: pinned to @v1.2.0, you get v1.2.0's scripts.
      #
      #   repo-template ITSELF -> the workspace. Two reasons, both decisive. Bootstrap: this repo's
      #                 PRs cannot check out a tag that Phase A has not cut yet, or the PR that cuts
      #                 it is red on its own account. And a PR that CHANGES a gate script must be
      #                 exercised by the run reviewing it, rather than judged by the released copy of
      #                 the script it is replacing.
      #
      # The cost of the second path is real and is recorded in the spec's Open items: on this repo's
      # own PRs the guard is again supplied by the PR it judges. template-tests runs on the same PR
      # and test_guard_matrix.sh asserts the matrix directly, so an `exit 0` rewrite turns a REQUIRED
      # context red — but a PR that edits the script and its suite together defeats that.
      - name: Resolve where the gate scripts come from
        id: scripts_src
        env:
          JOB_WORKFLOW_REF: ${{ github.job_workflow_ref }}
        run: |
          set -euo pipefail
          if [ "${GITHUB_REPOSITORY}" = "Avenue-Z/repo-template" ]; then
            echo "local=true" >> "${GITHUB_OUTPUT}"
            echo "::notice::gate scripts: this is repo-template — using the workspace copy"
          else
            # An empty job_workflow_ref here means we are not running as a called workflow in a repo
            # that is not the template, which should be impossible. Refuse rather than guess a ref:
            # guessing means staging SOMETHING and reporting a verdict from it.
            [ -n "${JOB_WORKFLOW_REF:-}" ] || {
              echo "::error::github.job_workflow_ref is empty and this is not repo-template — refusing to stage gate scripts from an unknown ref"; exit 1; }
            echo "local=false" >> "${GITHUB_OUTPUT}"
            echo "ref=${JOB_WORKFLOW_REF##*@}" >> "${GITHUB_OUTPUT}"
            echo "::notice::gate scripts: staging from Avenue-Z/repo-template@${JOB_WORKFLOW_REF##*@}"
          fi

      # actions/checkout's `path:` is documented as a path UNDER GITHUB_WORKSPACE and it will not
      # write outside it, so this cannot land directly in RUNNER_TEMP. Hence the subdirectory, the
      # `install` below, and the `rm -rf` — the same three-step shape the base-branch checkout used,
      # with only its source changed.
      - name: Check out the template at the ref this workflow was called at
        if: steps.scripts_src.outputs.local == 'false'
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          repository: Avenue-Z/repo-template
          ref: ${{ steps.scripts_src.outputs.ref }}
          persist-credentials: false
          path: .trusted-template

      - name: Stage the trusted scripts outside the workspace
        env:
          # Via env, not interpolated into the script body. checks.yml:156-158 states the rule and
          # the reason: `${{ }}` inside a `run:` is textual substitution, not a shell variable. This
          # particular value is derived from GITHUB_REPOSITORY and is not attacker-influenced, but a
          # file that keeps the rule everywhere is the one where a violation stands out.
          LOCAL_SRC: ${{ steps.scripts_src.outputs.local }}
        run: |
          set -euo pipefail
          src=scripts
          [ "${LOCAL_SRC}" = "true" ] || src=.trusted-template/scripts
          mkdir -p "${RUNNER_TEMP}/trusted-scripts"
          for s in check-base-branch.sh sca-gate.sh ci-aggregate-gate.sh; do
            [ -f "${src}/${s}" ] || { echo "::error::${src}/${s} is missing — refusing to run a gate with no script"; exit 1; }
            install -m 0755 "${src}/${s}" "${RUNNER_TEMP}/trusted-scripts/"
          done
          # RUNNER_TEMP is outside GITHUB_WORKSPACE, so the staged copies survive and are never
          # scanned. The SOURCE directory is not: osv-scanner walks the filesystem (`scan -r ./`), so
          # a second tree left inside the workspace gets scanned too — and a PR whose whole purpose is
          # to FIX a vulnerable dependency would still fail on the staged copy's old manifest. Delete
          # it here, BEFORE any scanner runs. Do not move this line down.
          rm -rf .trusted-template
```

Then update the two remaining references. The SCA step (currently `:227`) becomes:

```yaml
          "${RUNNER_TEMP}/trusted-scripts/sca-gate.sh" osv.json .github/sca-policy.json
```

And the verdict step's `GATE` resolution (currently `:250-258`) becomes:

```bash
          # The trusted, staged copy is the ONLY acceptable source, on every event. A workspace
          # fallback would let a PR supply its own verdict logic, and in a consumer it would break the
          # weekly audit outright once Phase E deletes the local copies.
          GATE="${RUNNER_TEMP}/trusted-scripts/ci-aggregate-gate.sh"
          [ -x "${GATE}" ] || { echo "::error::the trusted verdict script is missing — refusing to report a verdict"; exit 1; }
```

Leave the `args=(...)` lines below it exactly as they are — `test_checks_verdict.sh` drives them and
the guard is still only named on `pull_request`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash template-tests/test_guard_matrix.sh && bash template-tests/test_sca.sh && bash template-tests/test_checks_verdict.sh`
Expected: three × `ALL PASS`.

- [ ] **Step 5: Run the whole suite**

Run: `for t in template-tests/test_*.sh; do bash "$t" >/dev/null || echo "FAIL $t"; done; echo done`
Expected: no `FAIL` lines. `test_action_pins.sh` matters here — the new `actions/checkout` must carry
the same SHA as the existing one and as every `templates/*/.github/workflows/ci.yml`.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/checks.yml template-tests/test_guard_matrix.sh template-tests/test_sca.sh template-tests/test_checks_verdict.sh
git commit -m "feat: stage the gate scripts from the called workflow's own ref"
```

---

### Task 4: The file-gated required context

One ruleset file cannot require both `checks` and `checks / checks`. The context moves out of the JSON
and into the script that already makes exactly this decision for `ci` and `template-tests`.

**Files:**
- Modify: `.github/rulesets/repo-ruleset.json:33-43`
- Modify: `scripts/apply-rulesets.sh:80-99`
- Test: `template-tests/test_rulesets.sh:98-110`, `template-tests/test_apply_rulesets.sh:24-42`

**Interfaces:**
- Consumes: `checks.yml`'s `workflow_call` declaration from Task 2 — that string is the discriminator.
- Produces: `apply-rulesets.sh` prints exactly one of `        required: checks` or
  `        required: checks / checks`, and never both.

- [ ] **Step 1: Write the failing tests**

In `template-tests/test_rulesets.sh`, replace `:105-106` (`expected=$(printf 'checks')` and the
`assert_eq` under it) with:

```bash
# NO CONTEXT IS BAKED IN ANY MORE, and that is the fix for a collision, not a weakening.
# repo-ruleset.json is ONE file applied to BOTH this repo and every generated repo
# (apply-rulesets.sh:78, and its comment at :85-88). repo-template reports literally `checks`; a
# migrated consumer reports `checks / checks`. Whichever name were baked in, the other population
# would require a context nothing reports — which does not fail their PRs, it hangs them PENDING
# FOREVER. So the context is added by apply-rulesets.sh, from the local checks.yml, like ci and
# template-tests already are.
assert_eq "" "$contexts" "$REPO_RULESET bakes in NO status-check context (apply-rulesets.sh adds it)"
```

In `template-tests/test_apply_rulesets.sh`, replace `:31` (the
`assert_match "'checks' is listed as required"` line) with:

```bash
  # THIS repo's checks.yml declares workflow_call, so it is the template and reports plain `checks`.
  assert_match   "'checks' is required here (this checks.yml declares workflow_call)" 'required: checks$' "$out"
  assert_nomatch "'checks / checks' is NOT required here" 'required: checks / checks' "$out"

  # THE OTHER BRANCH. Asserting only the branch that happens to hold in this repo is how the consumer
  # branch ships untested — and the consumer branch is the one that runs in 11 repos. Drive the script
  # against a caller-shaped checks.yml in a throwaway clone.
  echo "apply-rulesets: a CALLER's checks.yml requires the renamed 'checks / checks' context"
  CALLERDIR="$(mktemp -d)"
  git clone -q . "${CALLERDIR}/repo"
  cat > "${CALLERDIR}/repo/.github/workflows/checks.yml" <<'CALLER'
name: checks
on:
  pull_request:
    types: [opened, edited, reopened, synchronize]
jobs:
  checks:
    uses: Avenue-Z/repo-template/.github/workflows/checks.yml@v1
CALLER
  cout="$(cd "${CALLERDIR}/repo" && ./scripts/apply-rulesets.sh --dry-run 2>&1 || true)"
  assert_match   "a caller requires 'checks / checks'" 'required: checks / checks' "$cout"
  assert_nomatch "a caller does NOT require the plain 'checks' context" 'required: checks$' "$cout"
  rm -rf "${CALLERDIR}"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash template-tests/test_rulesets.sh; bash template-tests/test_apply_rulesets.sh`
Expected: `test_rulesets.sh` fails (`expected ''`, got `'checks'`). `test_apply_rulesets.sh` fails the
caller branch — the script prints `required: checks` regardless of the workflow's shape.

- [ ] **Step 3: Empty the baked-in context list**

In `.github/rulesets/repo-ruleset.json`, replace the `required_status_checks` rule's parameters
(`:35-42`) with:

```json
      "parameters": {
        "strict_required_status_checks_policy": false,
        "required_status_checks": []
      }
```

- [ ] **Step 4: Teach `apply-rulesets.sh` the decision**

In `scripts/apply-rulesets.sh`, immediately after the `add_context` helper's closing `}` (currently
`:97`), extend the comment block above it with the `checks` case and add the call, so that the three
`add_context` invocations read:

```bash
# The `checks` context is NOT baked into repo-ruleset.json, because that file is shared by the
# template and by every generated repo and the two report DIFFERENT context names:
#
#   repo-template  -> checks.yml is the reusable workflow itself. Its pull_request runs are ordinary
#                     top-level jobs, so the context is literally `checks`.
#   a generated repo -> checks.yml is a CALLER. A called job's context is `<caller-job> / <called-job>`,
#                     so the context is `checks / checks`.
#
# Requiring the wrong one does not fail a PR — it hangs it PENDING FOREVER. `workflow_call` in the
# local checks.yml is the discriminator, and it is a discriminator rather than a guess because
# template-tests/test_reusable_contract.sh asserts that declaration is present.
if [ ! -f .github/workflows/checks.yml ]; then
  info "no .github/workflows/checks.yml — not requiring any 'checks' context"
elif grep -qE '^ *workflow_call:' .github/workflows/checks.yml; then
  add_context 'checks'          .github/workflows/checks.yml "this checks.yml IS the reusable workflow"
else
  add_context 'checks / checks' .github/workflows/checks.yml "this checks.yml is a caller; a called job reports '<caller>/<called>'"
fi
add_context ci             .github/workflows/ci.yml             "a required check with no workflow hangs every PR pending forever"
add_context template-tests .github/workflows/template-tests.yml "this workflow is the template's own, and init-repo.sh removes it"
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bash template-tests/test_rulesets.sh && bash template-tests/test_apply_rulesets.sh`
Expected: two × `ALL PASS`. Note `test_apply_rulesets.sh` skips its live blocks without org access
(`lib.sh:26-30`); the `--dry-run` assertions above run regardless.

- [ ] **Step 6: Verify by hand, since this is the brick-a-repo change**

Run: `./scripts/apply-rulesets.sh --dry-run`
Expected: the `required status checks:` list contains `checks` and `template-tests`, and **not**
`checks / checks` and **not** `ci`. Read the output; do not infer it from the exit code.

- [ ] **Step 7: Run the whole suite and commit**

```bash
for t in template-tests/test_*.sh; do bash "$t" >/dev/null || echo "FAIL $t"; done
shellcheck scripts/apply-rulesets.sh
git add .github/rulesets/repo-ruleset.json scripts/apply-rulesets.sh template-tests/test_rulesets.sh template-tests/test_apply_rulesets.sh
git commit -m "feat: file-gate the checks context so one ruleset serves both populations"
```

---

### Task 5: `init-repo.sh` writes a caller

**Files:**
- Modify: `scripts/init-repo.sh` (after the `rm -f .github/workflows/template-tests.yml` line, `:371`)
- Test: `template-tests/test_init_repo.sh:46`

**Interfaces:**
- Consumes: the `workflow_call` declaration from Task 2 (the generated caller points at it).
- Produces: a generated `.github/workflows/checks.yml` containing
  `uses: Avenue-Z/repo-template/.github/workflows/checks.yml@v1` and no `workflow_call`.

- [ ] **Step 1: Write the failing test**

In `template-tests/test_init_repo.sh`, replace `:46` (`assert_file "checks.yml survived ..."`) with:

```bash
# checks.yml SURVIVES, but INVERTED: a generated repo gets a nine-line CALLER, not a copy of the
# 260-line gate. The copy is what froze 11 repos on the version they were born with.
assert_file "checks.yml is present (as a caller)" .github/workflows/checks.yml
gen_checks="$(cat .github/workflows/checks.yml)"
assert_match "the generated checks.yml calls the template's reusable workflow" \
  'uses: Avenue-Z/repo-template/\.github/workflows/checks\.yml@v1' "$gen_checks"
# THE HALF THAT MATTERS. If init-repo.sh ever goes back to copying the file, the copy would carry
# `on: workflow_call` — and a workflow whose ONLY trigger is workflow_call never runs in the repo it
# sits in. It would enforce nothing, emit no error, and show an empty Actions tab. Asserting only
# that the file exists is what would let that ship green.
assert_nomatch "the generated checks.yml is NOT a copy of the reusable workflow" \
  'workflow_call' "$gen_checks"
assert_match "the caller still declares its own triggers (they cannot be inherited)" \
  'pull_request' "$gen_checks"
# Template-only artifacts must not ship. reusable-contract.json is the template's own golden file and
# advance-v1.yml force-moves a tag; neither has any business in a generated repo.
assert_no_file "the golden contract file did not ship" .github/reusable-contract.json
assert_no_file "the v1 advance workflow did not ship" .github/workflows/advance-v1.yml
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash template-tests/test_init_repo.sh`
Expected: FAIL — the generated `checks.yml` is still the verbatim copy, so the `uses:` assertion fails
and the `workflow_call` one fails too.

- [ ] **Step 3: Write the caller in `init-repo.sh`**

In `scripts/init-repo.sh`, immediately after `rm -f .github/workflows/template-tests.yml` (`:371`),
insert:

```bash
# A GENERATED REPO GETS A CALLER, NOT A COPY. Copying checks.yml is what froze 11 repos on the
# version they were born with: improving the gate here improved nothing anywhere else, because there
# was no channel. The caller is nine lines and it tracks the moving v1 tag.
#
# The triggers live HERE and not in the reusable workflow, because a workflow_call workflow cannot
# define `on:` for its consumers. That is inherent to the mechanism: the DECISIONS propagate, the
# TRIGGERING does not. Changing the audit schedule later is a PR per repo.
#
# No `with:` and no `secrets: inherit`: checks.yml declares no inputs and needs no secrets (it
# installs gitleaks from a checksummed release tarball rather than using gitleaks-action).
cat > .github/workflows/checks.yml <<'CALLER'
name: checks
on:
  # `edited` is load-bearing: a PR retargeted at a new base must be re-judged, and it is the only
  # event that fires on a base change.
  pull_request:
    types: [opened, edited, reopened, synchronize]
  # The weekly repo-wide audit. gitleaks scans full history here, and an advisory published overnight
  # makes yesterday's clean dependency tree dirty without anything in the tree changing.
  schedule:
    - cron: '0 6 * * 1'
permissions:
  contents: read
jobs:
  # THIS JOB KEY IS THE STATUS-CHECK CONTEXT. A called job reports as `<caller-job> / <called-job>`,
  # so this reports `checks / checks`, and scripts/apply-rulesets.sh requires exactly that string.
  # Renaming this job renames the check — and a required check that no longer reports does not fail
  # a PR, it hangs it PENDING FOREVER.
  checks:
    uses: Avenue-Z/repo-template/.github/workflows/checks.yml@v1
CALLER
info "wrote .github/workflows/checks.yml as a caller of repo-template@v1"

# Template-only artifacts. reusable-contract.json is the golden surface file that gates the v1 tag,
# and advance-v1.yml force-moves that tag — a generated repo has no business carrying either.
rm -f .github/reusable-contract.json .github/workflows/advance-v1.yml
```

- [ ] **Step 4: Run it to verify it passes**

Run: `bash template-tests/test_init_repo.sh`
Expected: `ALL PASS`. This suite clones into a temp dir and runs `init-repo.sh` for real, so it needs
a git identity — `git config --global user.name` and `user.email` must be set, as
`template-tests.yml:88-91` does on the runner.

- [ ] **Step 5: Run the whole suite and commit**

```bash
for t in template-tests/test_*.sh; do bash "$t" >/dev/null || echo "FAIL $t"; done
shellcheck scripts/init-repo.sh
git add scripts/init-repo.sh template-tests/test_init_repo.sh
git commit -m "feat: generate a caller workflow instead of copying checks.yml"
```

---

### Task 6: The layer-2 self-call

Proves `checks.yml` is callable at all. It has to be a **job of `template-tests.yml`**, because the
advance workflow chains off that workflow's run — a self-call published as its own workflow would gate
nothing, and `v1` could ship a workflow that cannot be called.

**Files:**
- Modify: `.github/workflows/template-tests.yml`
- Test: `template-tests/test_reusable_contract.sh` (one added assertion)

**Interfaces:**
- Consumes: `checks.yml`'s `workflow_call` from Task 2.
- Produces: a job named `self-call` in the `template-tests` workflow, whose result is part of that
  workflow run's conclusion — which is what Task 7 reads.

- [ ] **Step 1: Write the failing test**

Append to `template-tests/test_reusable_contract.sh`, immediately before `finish`:

```bash
echo "reusable contract: the self-call gates the tag (layer 2 of the spec's §4)"
TT=.github/workflows/template-tests.yml
tt="$(cat "$TT")"
# It must live INSIDE template-tests.yml. advance-v1.yml chains off the template-tests workflow RUN,
# so a self-call published as its own workflow would not gate anything and v1 could advance carrying a
# reusable workflow that is not callable at all — the one failure this layer exists to catch.
assert_match "template-tests.yml calls checks.yml locally" 'uses: \./\.github/workflows/checks\.yml' "$tt"
# Push-only. On every PR it would be one extra billed job per PR across the fleet, in a design whose
# premise is that job COUNT is the bill.
assert_match "the self-call runs on push, not on every PR" "github\.event_name == 'push'" "$tt"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash template-tests/test_reusable_contract.sh`
Expected: FAIL on both new assertions.

- [ ] **Step 3: Add the self-call job**

Append to `.github/workflows/template-tests.yml`, at the same indentation as the existing
`template-tests:` job:

```yaml
  # LAYER 2 OF THE v1 GATE (spec §4). The bash suite above proves the gate SCRIPTS decide correctly.
  # It cannot prove the WORKFLOW is callable — a reusable workflow with a malformed `on: workflow_call`
  # block, a bad `uses:` path or an undeclared input fails at expansion, before any script runs.
  #
  # IT LIVES HERE, not in its own workflow file, deliberately. advance-v1.yml chains off the
  # `template-tests` workflow RUN, so anything outside this file does not gate the tag, and v1 could
  # advance carrying a workflow nobody can call.
  #
  # PUSH ONLY. On pull_request this would be one extra billed job on every PR in every repo, and job
  # count is the bill. Be honest about what that costs in coverage: on a push event the called
  # workflow takes its non-PR path, so this proves the workflow RESOLVES, EXPANDS and RUNS GREEN — it
  # does not exercise the base-branch guard or the PR-scoped secret scan. The suite above covers those.
  #
  # `if:` is permitted on a `uses:` job. `continue-on-error` is NOT — learned the hard way in
  # data-contract's gate-selftest.yml — which is why this is a happy-path test by construction and
  # cannot assert "this call failed and that is fine".
  #
  # A same-repo self-call also cannot prove CROSS-REPO ref resolution: a correct and a broken
  # job_workflow_ref resolve the same valid ref from inside this repo. That is layer 4, and Phase B
  # covers it once, by hand, on data-warehouse.
  self-call:
    if: github.event_name == 'push'
    uses: ./.github/workflows/checks.yml
```

- [ ] **Step 4: Run it to verify it passes**

Run: `bash template-tests/test_reusable_contract.sh`
Expected: `ALL PASS`.

- [ ] **Step 5: Validate the YAML parses as Actions will read it**

Run: `python3 -c "import yaml,sys; d=yaml.safe_load(open('.github/workflows/template-tests.yml')); print(sorted(d['jobs']))"`
Expected: `['self-call', 'template-tests']`.

- [ ] **Step 6: Run the whole suite and commit**

```bash
for t in template-tests/test_*.sh; do bash "$t" >/dev/null || echo "FAIL $t"; done
git add .github/workflows/template-tests.yml template-tests/test_reusable_contract.sh
git commit -m "feat: gate the tag on a self-call that proves checks.yml is callable"
```

> **CI-only half:** whether the self-call actually goes green cannot be observed until billing is
> restored. Its first real run is on the push to `dev` that merges this plan's PR. Do not treat a
> locally green suite as evidence that the call works — that is precisely the "failure to verify
> treated as a verified pass" the spec's Step 0 warns about.

---

### Task 7: The advance workflow

**Files:**
- Create: `.github/workflows/advance-v1.yml`
- Create: `template-tests/test_advance_v1.sh`

**Interfaces:**
- Consumes: `.github/reusable-contract.json` (Task 2); the `template-tests` workflow name and its
  `self-call` job (Task 6); `init-repo.sh`'s cull, already extended in Task 5.
- Produces: a step named `decide` whose `run:` block is extracted by the test, driven by the env vars
  `ACKNOWLEDGED`, `TARGET_SHA`, `GITHUB_OUTPUT`, and which writes `advance=true` on success.

- [ ] **Step 1: Write the failing test**

Create `template-tests/test_advance_v1.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=template-tests/lib.sh disable=SC1091
source template-tests/lib.sh

WORKFLOW=.github/workflows/advance-v1.yml

# THE ADVANCE IS AN AUTOMATED FLEET-WIDE DEPLOY OF THE SECURITY GATES. Eleven repos execute whatever
# v1 points at, as their only gate. Two mechanics in this workflow are silent when wrong, so they are
# driven here against real git repositories rather than asserted by grep.

echo "advance-v1: the workflow exists and pins the tested commit, not the branch tip"
assert_file "$WORKFLOW exists" "$WORKFLOW"
wf="$(cat "$WORKFLOW")"
# A workflow_run-triggered run does NOT default to the commit that triggered the upstream workflow:
# GITHUB_SHA is the last commit on the DEFAULT BRANCH. Two merges in quick succession would therefore
# tag a commit template-tests never ran against.
assert_match "the checkout pins workflow_run.head_sha" \
  'github\.event\.workflow_run\.head_sha' "$wf"
assert_match "the checkout fetches full history and tags" 'fetch-depth: 0' "$wf"
assert_match "it chains off template-tests" 'workflows: \[template-tests\]' "$wf"
assert_match "it only acts on a successful upstream run" \
  "workflow_run\.conclusion == 'success'" "$wf"
assert_match "there is an explicit acknowledgement path for an additive change" \
  'acknowledge-contract-change' "$wf"

# Extract the decision block and drive it for real. Same idiom as test_checks_verdict.sh: the thing
# under test is the SHIPPED script, not a copy of it in this file.
DECIDE="$(mktemp)"; trap 'rm -f "${DECIDE}"' EXIT
python3 - "$WORKFLOW" > "$DECIDE" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for s in d['jobs']['advance']['steps']:
    if s.get('id') == 'decide':
        sys.stdout.write(s['run']); break
else:
    sys.exit("no step with id 'decide' in advance-v1.yml")
PY
if [ -s "$DECIDE" ]; then pass "the 'decide' step's script was extracted"; else fail "advance-v1.yml must contain a step with id 'decide'"; fi

# <msg> <expected-exit> <acknowledged> <contract-changed-since-v1> <v1-exists>
scenario() {
  local msg="$1" want="$2" ack="$3" changed="$4" have_v1="$5" rc=0
  local d; d="$(mktemp -d)"
  (
    cd "$d"
    git init -q .; git config user.email t@t; git config user.name t
    # An origin, so the fixture resembles the repo the decide block actually runs in. (Checked:
    # `git fetch --tags --force` exits 0 with no remote configured, so this is not load-bearing
    # today — it is insurance against a decide block that later needs a real fetch to mean anything.)
    git remote add origin "$d"
    mkdir -p .github
    echo '{"job":"checks"}' > .github/reusable-contract.json
    echo base > f; git add -A; git commit -qm base
    [ "$have_v1" = no ] || git tag v1
    if [ "$changed" = yes ]; then echo '{"job":"checks","inputs":["new"]}' > .github/reusable-contract.json; fi
    echo more >> f; git add -A; git commit -qm next
  )
  local target; target="$(git -C "$d" rev-parse HEAD)"
  # $DECIDE is already absolute (mktemp), so it survives the cd.
  ( cd "$d" && ACKNOWLEDGED="$ack" TARGET_SHA="$target" GITHUB_OUTPUT="$d/out" \
      bash "$DECIDE" >/dev/null 2>&1 ) || rc=$?
  assert_eq "$want" "$rc" "$msg"
  rm -rf "$d"
}

echo "advance-v1: the tripwire refuses on a moved contract and keeps refusing"
scenario "contract unchanged since v1 -> advance"                  0 false no  yes
scenario "contract changed since v1 -> REFUSE"                     1 false yes yes
# THE STICKY PROPERTY. Comparing against the PREVIOUS COMMIT would make the refusal one-shot: the next
# unrelated push sees an unchanged file, passes, and advances v1 straight past the breaking commit.
# Comparing against what v1 POINTS AT is what makes the refusal hold until a human acts. The scenario
# above already encodes it — `next` does not touch the contract file, yet the diff base is still v1.
scenario "an unrelated push after a refused one -> STILL REFUSE"   1 false yes yes
echo "advance-v1: an unresolvable comparison refuses, and an acknowledged change proceeds"
# "I could not tell" is not "nothing changed" — the same posture apply-rulesets.sh:57-62 takes.
scenario "v1 does not resolve -> REFUSE, do not guess"             1 false no  no
# The way out for an ADDITIVE change (a new input WITH a default), which §1 calls backward-compatible
# but which still moves the golden file. Without this the design would call additive changes
# non-breaking and then refuse to ship them.
scenario "an acknowledged additive change -> advance"              0 true  yes yes

finish
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash template-tests/test_advance_v1.sh`
Expected: FAIL at the first assertion — `.github/workflows/advance-v1.yml` does not exist.

- [ ] **Step 3: Write the advance workflow**

Create `.github/workflows/advance-v1.yml`:

```yaml
name: advance-v1

# MOVES THE v1 TAG. Eleven repos call Avenue-Z/repo-template/.github/workflows/checks.yml@v1 as their
# only security gate, so this workflow is an automated fleet-wide deploy. It is deliberately the ONLY
# thing that moves the tag: a human-moved tag is a human-forgotten tag, and that failure is silent —
# the fleet just stops receiving fixes, with no red check anywhere to say so.
#
# THIS FILE IS TEMPLATE-ONLY. scripts/init-repo.sh deletes it; a generated repo has no business
# carrying a workflow that force-moves a tag. test_init_repo.sh asserts the removal.

on:
  # Chains off the RESULT of template-tests rather than re-running the suite. That run includes the
  # self-call job, so "the reusable workflow is callable" gates the tag too.
  workflow_run:
    workflows: [template-tests]
    types: [completed]
    branches: [main]
  # The way out for a change that moves the golden contract file but is backward-compatible — a new
  # input WITH a default. The tag is still moved by this workflow, never by a person at a keyboard;
  # what a human supplies is the acknowledgement, in the open, that the surface moved and it was
  # additive.
  workflow_dispatch:
    inputs:
      acknowledge-contract-change:
        description: 'SHA on main to advance v1 to, for an ADDITIVE contract change'
        required: true

# The only elevated permission in this design, and it exists solely to move a tag. The v1 tag ruleset
# carries the GitHub Actions app as its one bypass actor, or this write is refused by the ruleset
# regardless of the token's permissions.
permissions:
  contents: write

jobs:
  advance:
    if: github.event_name == 'workflow_dispatch' || github.event.workflow_run.conclusion == 'success'
    runs-on: ubuntu-latest
    steps:
      # A workflow_run-triggered run resolves GITHUB_SHA to the LAST COMMIT ON THE DEFAULT BRANCH, not
      # to the commit that triggered the upstream workflow. Two merges in quick succession would put
      # the second one's tip in the workspace while the FIRST one's result is what succeeded — and v1
      # would be moved onto a commit template-tests never ran against. Pin it explicitly.
      # fetch-depth: 0 is not decoration: the decision below needs history and tags.
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          ref: ${{ github.event_name == 'workflow_dispatch' && inputs.acknowledge-contract-change || github.event.workflow_run.head_sha }}
          fetch-depth: 0

      - name: decide whether v1 may advance
        id: decide
        env:
          ACKNOWLEDGED: ${{ github.event_name == 'workflow_dispatch' }}
          TARGET_SHA: ${{ github.event_name == 'workflow_dispatch' && inputs.acknowledge-contract-change || github.event.workflow_run.head_sha }}
        run: |
          set -euo pipefail
          git fetch --tags --force >/dev/null 2>&1 || {
            echo "::error::could not fetch tags — refusing to advance v1"; exit 1; }

          if [ "${ACKNOWLEDGED}" = "true" ]; then
            echo "::notice::contract change acknowledged by hand — skipping the tripwire comparison"
            echo "advance=true" >> "${GITHUB_OUTPUT}"
            exit 0
          fi

          # THE COMPARISON BASE IS WHAT v1 POINTS AT, not the previous commit, and that is the whole
          # design. Against the previous commit the refusal would be ONE-SHOT: a breaking commit lands
          # and this refuses; the next unrelated push touches nothing in the contract file, passes, and
          # advances v1 STRAIGHT PAST the breaking commit. Against v1 the base does not move until v1
          # does, so the refusal holds until a human acts.
          #
          # The workflow_run payload carries head_sha and head_commit but NO commit list and NO
          # changed-file set, so there is nothing to read here — it has to be computed.
          base="$(git rev-parse -q --verify 'refs/tags/v1^{commit}')" || {
            echo "::error::v1 does not resolve. It is cut BY HAND once, in Phase A; after that this workflow owns it. Refusing to guess a base."; exit 1; }

          changed="$(git diff --name-only "${base}" "${TARGET_SHA}" -- .github/reusable-contract.json)" || {
            echo "::error::could not diff ${base}..${TARGET_SHA} — refusing to advance v1"; exit 1; }

          if [ -n "${changed}" ]; then
            echo "::error::.github/reusable-contract.json has changed since v1 — the consumer-visible surface moved."
            echo "Cut v2 by hand if this is a break (a renamed job, a required input, or a new failure"
            echo "condition unrelated to the caller's own content). If it is ADDITIVE — a new input WITH"
            echo "a default — re-run this workflow via workflow_dispatch naming the SHA."
            exit 1
          fi
          echo "advance=true" >> "${GITHUB_OUTPUT}"

      - name: move v1 and cut the next point tag
        if: steps.decide.outputs.advance == 'true'
        env:
          TARGET_SHA: ${{ github.event_name == 'workflow_dispatch' && inputs.acknowledge-contract-change || github.event.workflow_run.head_sha }}
        run: |
          set -euo pipefail
          git config user.name  "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

          # The immutable point tag is the ONLY thing that makes "pin to the last good version" a
          # sentence with an argument. Without it the previous v1 is gone and a consumer would have to
          # pin to a SHA dug out of the reflog — in practice they delete the caller and lose the gate.
          last="$(git tag -l 'v1.*.0' | sed -E 's/^v1\.([0-9]+)\.0$/\1/' | grep -E '^[0-9]+$' | sort -n | tail -1 || true)"
          next="v1.$(( ${last:-0} + 1 )).0"
          git tag -a "${next}" "${TARGET_SHA}" -m "checks.yml reusable workflow ${next}"
          git push origin "refs/tags/${next}"

          git tag -f v1 "${TARGET_SHA}"
          git push --force origin refs/tags/v1
          echo "::notice::v1 -> ${TARGET_SHA} (also cut ${next})"
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash template-tests/test_advance_v1.sh`
Expected: `ALL PASS` — including the two refusal scenarios and the acknowledged one.

- [ ] **Step 5: Confirm the workflow does not ship**

Run: `bash template-tests/test_init_repo.sh`
Expected: `ALL PASS`, including `the v1 advance workflow did not ship` — Task 5 already added the
`rm -f`, so this is the assertion proving it covers a file that now exists.

- [ ] **Step 6: Run the whole suite and commit**

```bash
for t in template-tests/test_*.sh; do bash "$t" >/dev/null || echo "FAIL $t"; done
shellcheck template-tests/test_advance_v1.sh
git add .github/workflows/advance-v1.yml template-tests/test_advance_v1.sh
git commit -m "feat: advance v1 automatically, gated on a sticky contract tripwire"
```

> **CI-only half:** the tag push itself cannot be exercised locally, and it will fail until Task 10
> creates `v1` and the tag ruleset's bypass actor. The `decide` block — which is where the two silent
> failure modes live — is fully covered above.

---

### Task 8: The documentation the design makes load-bearing

**Files:**
- Modify: `SECURITY.md`
- Modify: `CONTRIBUTING.md`
- Modify: `docs/ADOPTION.md`

**Interfaces:**
- Consumes: everything above.
- Produces: nothing another task reads.

- [ ] **Step 1: Record the self-modification hole's new shape in `SECURITY.md`**

Find the existing passage about a PR being able to rewrite `checks.yml` and neuter its own gates, and
append:

```markdown
This hole does not close under the reusable-workflow design — it **changes shape, and gets subtler**.
Actions still reads the workflow file from the PR head. Previously neutering the gates meant rewriting
a 262-line `checks.yml` in a way a reviewer would notice at a glance. Now it is changing `@v1` to
`@my-branch` on **one line of a nine-line file**. Same hole, materially easier to miss in review.

**`.github/` being code-owned therefore goes from good practice to load-bearing.** Note what that
currently requires and does not yet have: `repo-template` ships `.github/CODEOWNERS.tmpl` and only
`scripts/init-repo.sh` instantiates it, so this repository has no live CODEOWNERS at all, and the
shipped ruleset sets `require_code_owner_review: false`. In both populations code ownership is a
convention today, not a control.
```

- [ ] **Step 2: Record the marketplace-companion rule in `CONTRIBUTING.md`**

Append to the governance section:

```markdown
### Governance changes need a companion marketplace PR

`Avenue-Z/claude-marketplace` ships the `repo-template-first` skill, which describes this repo's
workflows and what a generated repo contains. It is a **third copy** of these conventions, after the
template and the repos derived from it. Nothing syncs it automatically and nothing is going to: at this
size a sync mechanism would cost more than the drift does. So it is a rule instead — **a PR that
changes the governance workflows, the branch matrix, or what `init-repo.sh` generates opens a companion
PR against `Avenue-Z/claude-marketplace` in the same sitting.**
```

- [ ] **Step 3: Say the same thing where an adopter will meet it, in `docs/ADOPTION.md`**

Append to the maintenance section:

```markdown
### Where the gate actually lives

A repo generated after 2026-09 carries a nine-line `.github/workflows/checks.yml` that calls
`Avenue-Z/repo-template/.github/workflows/checks.yml@v1`. The gate's logic — the branch matrix, the
secret scan, the dependency policy — lives in the template and reaches this repo through the moving
`v1` tag. **There is nothing to update here when the gate improves.**

Two consequences worth knowing before they surprise you:

- **`.github/sca-policy.json` is still yours.** The tier is per-repo on purpose: a client-facing repo
  and an internal one legitimately differ.
- **Your triggers are still yours.** A reusable workflow cannot define `on:` for its callers, so the
  `pull_request` types and the weekly cron live in your file. Changing the audit schedule fleet-wide is
  a PR per repo.

If `@v1` ever breaks your repo, pin the caller to the last good point tag (`@v1.N.0`) and open an issue
against the template. Do not delete the caller — that removes the only gate the repo has.
```

- [ ] **Step 4: Verify the docs suites still pass**

Run: `bash template-tests/test_contracts_docs.sh && bash template-tests/test_sca.sh && bash template-tests/test_init_repo.sh`
Expected: three × `ALL PASS`. `test_sca.sh:161-163` greps `SECURITY.md` and `docs/ADOPTION.md` for
existing strings — appending must not disturb them.

- [ ] **Step 5: Run the whole suite and commit**

```bash
for t in template-tests/test_*.sh; do bash "$t" >/dev/null || echo "FAIL $t"; done
git add SECURITY.md CONTRIBUTING.md docs/ADOPTION.md
git commit -m "docs: record where the gate lives and what the design makes load-bearing"
```

- [ ] **Step 6: Open the PR**

```bash
git push -u origin HEAD:refs/heads/feat/reusable-checks-workflow
gh pr create --base dev --title "feat: publish checks.yml as a reusable workflow behind v1" --body "$(cat <<'BODY'
Implements Phase A of template-docs/specs/2026-09-09-reusable-workflows-design.md.

`checks.yml` becomes callable; the gate scripts are staged from the template at the ref the workflow
was called at; the required context is decided by `apply-rulesets.sh` rather than baked into a ruleset
file shared by two populations; `init-repo.sh` generates a caller; and a golden contract file plus an
advance workflow move `v1` automatically, refusing while the consumer-visible surface has moved.

Tasks 1-8 are one PR on purpose: the design invalidates six suites, and `template-tests` is what gates
the `v1` advance, so it must not be red between them.

Not in this PR: the marketplace companion PR (separate repo) and the `v1` tag cut itself, which happens
once this reaches `main`.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
BODY
)"
```

Verify: `gh pr checks` shows `checks` and `template-tests` green. **Read the output.** Do not assert a
pass you have not seen — the suite passing on a laptop is not the same as the workflow running.

---

### Task 9: The companion marketplace PR

Executes in `Avenue-Z/claude-marketplace`, not in this checkout. The spec names four locations that go
stale; the frontmatter one is delicate because it is the skill's **trigger description**, so a careless
rewrite degrades *when the skill fires*, not merely what it says once fired.

**Files (in `Avenue-Z/claude-marketplace`):**
- Modify: `plugins/repo/skills/repo-template-first/SKILL.md:3` (frontmatter — the trigger description)
- Modify: `plugins/repo/skills/repo-template-first/SKILL.md:59`, `:65`, `:89`
- Modify: `plugins/repo/.claude-plugin/plugin.json:3`

- [ ] **Step 1: Clone and read before editing**

```bash
gh repo clone Avenue-Z/claude-marketplace /tmp/claude-marketplace
sed -n '1,10p;55,95p' /tmp/claude-marketplace/plugins/repo/skills/repo-template-first/SKILL.md
sed -n '1,10p' /tmp/claude-marketplace/plugins/repo/.claude-plugin/plugin.json
```

The line numbers above come from the spec and were not re-verified in this checkout. If they have
drifted, find the four passages by content — every mention of `guard-base-branch`, `secret-scan`, or
`sca` as *workflow names* — and treat the spec's table as the inventory, not as coordinates.

- [ ] **Step 2: Make the three body edits**

Each of `:59`, `:65`, `:89` describes the three-workflow layout that no longer exists. The facts they
must now state:

- The three governance workflows (`guard-base-branch`, `secret-scan`, `sca`) are **merged into a single
  `checks` workflow**. Three jobs became one, because GitHub bills every job rounded up to a whole
  minute and all three finished in under ten seconds.
- A repo generated from the template carries a **caller**, not a copy: nine lines pointing at
  `Avenue-Z/repo-template/.github/workflows/checks.yml@v1`. The gate's logic lives in the template and
  arrives through the moving `v1` tag.
- The required status-check context in a generated repo is **`checks / checks`**, not `checks` — a
  called job reports as `<caller-job> / <called-job>`. `:59`'s existing reasoning about
  `apply-rulesets.sh` and the `ci` context extends to this.
- A private repo on Free still has **no ruleset enforcement at all**; the workflow on PRs and
  convention are the whole control. That part of the skill was already right and must survive the edit.

- [ ] **Step 3: Edit the frontmatter description with the lightest possible touch**

Change only the workflow *names* inside the existing description — `guard-base-branch` and
`secret-scan` become `checks`. Do not restructure the sentence, reorder its clauses, or trim it: it is
the trigger description, and its phrasing is what decides whether the skill fires on "new repo for X",
"scaffold a service", `gh repo create`, and the rest. Same for `plugin.json:3`.

- [ ] **Step 4: Verify the skill still parses and fires**

```bash
cd /tmp/claude-marketplace && git diff --stat
python3 -c "import yaml,sys; print(yaml.safe_load(open('plugins/repo/skills/repo-template-first/SKILL.md').read().split('---')[1]))"
python3 -c "import json; json.load(open('plugins/repo/.claude-plugin/plugin.json')); print('plugin.json parses')"
```

Expected: the frontmatter parses to a dict with `name` and `description`; `plugin.json` parses.

- [ ] **Step 5: Open the PR**

```bash
cd /tmp/claude-marketplace
git checkout -b docs/checks-workflow-rename
git commit -am "docs: repo-template ships one checks workflow, generated repos ship a caller"
gh pr create --base dev --title "docs: update repo-template-first for the checks collapse and the v1 caller" --body "Companion to Avenue-Z/repo-template's Phase A. Four locations named the three-workflow layout, which the collapse already invalidated; a generated repo now carries a caller pointing at checks.yml@v1 and reports the context 'checks / checks'.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

---

### Task 10: Cut `v1` and protect it

**Blocked on:** Actions billing restored (Step 0), Tasks 1–8 merged all the way to `main`, and org-admin
rights on `Avenue-Z/repo-template`. This is the one time a human touches the tag — §1's rule is about
every advance *after* this.

**Files:** none in this repo. Ruleset state on GitHub.

- [ ] **Step 1: Promote the work to `main`**

```bash
gh pr create --base staging --head dev  --title "chore: promote reusable-workflow Phase A to staging"
gh pr create --base main    --head staging --title "chore: promote reusable-workflow Phase A to main"
```

Verify after each merge: `gh run list --branch staging --limit 3` and then `--branch main`. The
`template-tests` run on `main` must be green **including its `self-call` job** — that job is layer 2,
and this is its first real execution. If it is red, stop: `v1` must not be cut over a workflow that
cannot be called.

- [ ] **Step 2: Cut the tag, by hand, once**

```bash
git fetch origin main
git tag -a v1.0.0 origin/main -m "checks.yml reusable workflow v1.0.0"
git tag -a v1     origin/main -m "moving major tag; advanced by .github/workflows/advance-v1.yml"
git push origin refs/tags/v1.0.0 refs/tags/v1
```

Verify: `git ls-remote --tags origin | grep -E 'v1$|v1\.0\.0'` shows both, at the same SHA as
`origin/main`.

**Cut `v1` at or after the commit that introduced `.github/reusable-contract.json` — not before.** The
advance workflow diffs that path between what `v1` points at and the target. If `v1` sits on a commit
predating the file, every diff reports it as an addition and **every advance refuses, forever**, until
someone dispatches manually. It fails in the safe direction, but the symptom — a tag that never moves,
with a "the consumer contract has changed" error that names a file nobody touched — is confusing enough
to cost an afternoon. Cutting at `origin/main` after Phase A has landed satisfies this automatically;
the trap is only reachable if someone back-dates the tag.

- [ ] **Step 3: Protect the tag, with the one bypass actor that keeps the advance working**

Look the GitHub Actions app's id up rather than typing one from memory:

```bash
gh api /repos/Avenue-Z/repo-template/installation -q '.app_id, .app_slug'
```

Then create the ruleset. It targets `refs/tags/v1` **exactly** — the immutable `v1.N.0` point tags fall
outside it, so nothing blocks their creation:

```bash
gh api -X POST repos/Avenue-Z/repo-template/rulesets --input - <<'RULESET'
{
  "name": "v1-tag-protection",
  "target": "tag",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["refs/tags/v1"], "exclude": [] } },
  "bypass_actors": [
    { "actor_id": <APP_ID_FROM_STEP_ABOVE>, "actor_type": "Integration", "bypass_mode": "always" }
  ],
  "rules": [ { "type": "deletion" }, { "type": "non_fast_forward" } ]
}
RULESET
```

`bypass_actors: []` is this repo's house pattern and is **wrong here**: a ruleset applies to
`GITHUB_TOKEN` like any other actor, so an empty list would block the advance workflow from moving the
tag regardless of its `contents: write`. The residual — that the bypass is repo-scoped, so any workflow
in this repo requesting `contents: write` inherits it — is recorded in the spec's Open items.

- [ ] **Step 4: Prove the protection is real, in both directions**

```bash
# It must refuse a human.
git tag -f v1 HEAD~1 && git push --force origin refs/tags/v1
```

Expected: **rejected** by the ruleset. If this succeeds, the tag is not protected — undo it
(`git tag -f v1 <the right sha> && git push --force origin refs/tags/v1`) and fix the ruleset before
going further. A tag ruleset that silently does nothing is worse than none, because the design's
threat model assumes it works.

Then prove the workflow can still do what a human cannot: merge a trivial no-op commit to `main` and
watch `advance-v1` move `v1` and cut `v1.1.0`.

```bash
gh run list --workflow=advance-v1.yml --limit 3
git ls-remote --tags origin | grep -E 'v1$|v1\.1\.0'
```

- [ ] **Step 5: Prove the refusal path, once, deliberately**

Open a PR to `dev` that edits `.github/reusable-contract.json` (add a dummy input to the `inputs`
array) and a matching `inputs:` block in `checks.yml`, so `test_reusable_contract.sh` stays green. Once
it reaches `main`, `advance-v1` must **refuse** and print the "cut v2, or acknowledge" message, and
`v1` must not move. Then revert it.

This is the only way to observe the sticky refusal in production, and it is worth one deliberate cycle:
the failure it guards against — `v1` advancing past a breaking commit on the next unrelated push — is
invisible until eleven repos are already running it.

- [ ] **Step 6: Record the state**

Append a dated note to `docs/notes/` recording: the `v1` and `v1.0.0` SHAs, the app id used as the
bypass actor, and whether Steps 4 and 5 behaved as specified. Phase B starts from this state, and the
next person needs to know which of these were *observed* rather than assumed.

---

## What Phase A does not settle

Carried forward to Phase B's plan, and listed here so a reader of this document alone does not mistake
a green suite for a working design:

1. **The three Step 0 OPEN mechanics.** Whether a private repo can *execute* a reusable workflow from
   the public template; whether `actions/checkout` inside a called workflow resolves to the caller; and
   whether a consumer's default `GITHUB_TOKEN` can check out `Avenue-Z/repo-template` at all. The third
   is the single assumption the whole design rests on and it has not been tested even partially. **None
   of them can be answered from inside this repo** — a same-repo self-call resolves a correct and a
   broken ref identically.
2. **Layer 4.** "A failing gate turns the *caller* red" is provable only from a real consumer. Phase B
   covers it once, by hand, on `data-warehouse`.
3. **The `.github/sca-policy.json` hole.** The scripts move to a trusted ref; the tier dial they read
   does not.
4. **Clause-3 breaks.** A behaviour change that alters no declared surface passes all three layers and
   auto-deploys. Accepted risk, not a covered case.
