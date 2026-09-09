# Propagating CI/CD from the template with reusable workflows — design

## Why this exists

`scripts/init-repo.sh` ends with `rm -rf templates template-tests template-docs`. That line is the
whole point of the template — a generated repo carries none of the scaffolding's own machinery — and
it is also the reason the template cannot fix anything it has already shipped. **Eleven repos are
derived from this one, and every one of them holds a frozen byte-copy of the governance workflows as
they existed on the day it was scaffolded.** Improving `checks.yml` here improves nothing anywhere
else. There is no channel.

The cost of that is now measurable, in two currencies.

**Billed minutes.** The org is on GitHub Free: 2,000 Actions minutes a month for private repos.
Consumption was 2,944 in July and 2,860 in August; **September 1–8 alone burned 2,081** — a full
month's allowance in eight days, tracking to roughly 7,800/month. As of this writing Actions is
**billing-blocked org-wide**, and jobs are refused outright with *"The job was not started because
recent account payments have failed or your spending limit needs to be increased."* The optimisation
that fixes a large part of this already exists in this repo — `guard-base-branch.yml` + `sca.yml` +
`secret-scan.yml` collapsed into a single `checks.yml`, three jobs to one — and it is sitting on
`dev`. It has not reached `main`, so all 11 derived repos still run the old three-workflow layout,
and none of them would pick up the new one even after it lands.

**Drift.** The same argument runs in the other direction. A future tightening of the SCA policy, a
new branch prefix, a fix to the base-branch guard — each of those is currently an 11-PR chore that
nobody will do, so in practice it does not happen and the fleet diverges quietly.

`docs/ADOPTION.md:109` says *"There is no retrofit script, on purpose."* That rule stands, and it is
not what this document proposes to overturn. It was written about **pre-existing repos** — repos with
unknown history, unaudited secrets, and no relationship to the template, where bolting a secret gate
onto a tree nobody has read produces a red check with no owner and no fix. Repos **scaffolded from
the template** are a different population: their history begins at an `init-repo.sh` run, they were
audited at birth, and they already run these exact gates. Propagating a fix to a repo that is already
running the broken version of that fix is not retrofitting. It is maintenance.

## Step 0: billing, and what "unverified" means in this document

**Nothing in this design can be verified in CI until Actions billing is restored.** Jobs are refused
before a runner is assigned. This is the first task in the plan and it blocks every phase, including
Phase A.

That constraint is why this spec is unusually explicit about which of its claims were measured. Each
statement below marked *established* was checked during design, on this tree or via a live probe.
Statements marked **OPEN** were not, and the sections that depend on them say so at the point of use.
This repo's stated posture is that "a failure to verify is never treated as a verified pass"; a
design document written during a CI outage is exactly where that rule gets tested.

### Established

1. **A reusable workflow's check context is `<caller-job> / <called-job>`.** Proven by a live probe: a
   caller job `call` invoking a called job `probe` reported the context `call / probe`. **Moving
   `checks.yml` behind `workflow_call` therefore renames the check away from `checks`.** Everything in
   §1 and §3 about required contexts descends from this one fact.
2. **Rulesets are inert on the 9 private repos.** `GET /repos/.../rulesets` returns
   *403 Upgrade to GitHub Pro*. A context rename blocks nothing there. It is live only on
   `data-contract` (1 active ruleset) and `avenue-z-reporting-v2` (3).
3. **`checks.yml` needs no secrets.** It declares only `permissions: contents: read`, and installs
   gitleaks by downloading the release tarball against a checksum rather than using
   `gitleaks-action`, so there is no `GITLEAKS_LICENSE`. **Callers need no `secrets: inherit`.**
4. **Job count is the bill, not job duration.** `client-satisfaction-report`: 560 `ci` jobs billed 563
   minutes, with 99% of jobs finishing under 60 seconds. GitHub rounds every job up to a whole minute.
   `checks.yml`'s own header already states this ("a 21s job and a 12s job bill exactly the same").
5. **`continue-on-error` is forbidden on a `uses:` job.** Recorded in `data-contract`'s
   `gate-selftest.yml` comments, learned there the hard way. It constrains §4 layer 2.
6. **A same-repo self-call cannot prove cross-repo ref resolution.** Also from `gate-selftest.yml`:
   *"a correct and a broken `job.workflow_ref` resolve the same valid ref."* This is why §4's layer 4
   cannot be faked from inside this repo.
7. **`scripts/sca-gate.sh` already fail-safes on a missing policy file** — `sca-gate.sh:24-28`
   defaults to `client-facing` (strict) with a warning, verified by running it against a nonexistent
   path. No new code is needed for a consumer that has no `.github/sca-policy.json`.
8. **`init-repo.sh` ships `checks.yml` verbatim,** and `template-tests/test_init_repo.sh:46` asserts
   it survives. This is the trap in §2.
9. **Branch conventions are already followed.** 10 of 12 repos are 100% conforming.
   `client-satisfaction-report` has 3 stragglers, all initial-setup artifacts;
   `avenue-z-reporting-v2` has 37 of 148.
10. **`ci.yml` variation across the 6 template-shaped repos is only three axes**: the Python matrix
    (`["3.11","3.12","3.13"]` vs `["3.13"]`), the test command (`make check` vs an expanded
    ruff/mypy/`pytest -q`), and drifted pinned action SHAs. That small surface is what makes §6
    tractable.

### OPEN — must be settled empirically, in Phase B

- **Whether a private repo can execute a reusable workflow from the public template.** The evidence is
  strong but incomplete. The probe run *resolved and expanded the called workflow's job* — access
  resolution and parsing both succeeded — and was then refused at the billing gate before any step
  ran. **Access was observed; execution was not.** The entire design rests on this and it is not
  proven.
- **Whether `actions/checkout` inside a reusable workflow resolves to the caller or to the template.**
  The probe designed to answer this never executed. §2 assumes *caller*, which is the documented
  behaviour, but it is unconfirmed here and §2 is wrong in a specific, silent way if it is false: the
  scanners would scan the template's tree and report green on a repo they never looked at.

---

## Repo inventory

| Tier | Repos | Notes |
|---|---|---|
| Clean private (8) | `announcement-recapping`, `az-media-hits`, `az-utm-generator`, `client-satisfaction-report`, `dash-social-connection`, `data-warehouse`, `rippling-asana-pto`, `sf-sb-automation` | Standard 3 governance workflows + `ci.yml` |
| Partial | `noble-clone` | **Never had `sca.yml`** — no commit ever touched that path, no `.github/sca-policy.json`, and `scripts/` holds only `check-base-branch.sh`. Partial adoption, not a deliberate opt-out |
| Public + rulesets | `data-contract` | 1 active ruleset. Also carries `contract-gate.yml` (a working `workflow_call` reusable workflow) and `gate-selftest.yml` |
| Divergent | `avenue-z-reporting-v2` | Public, 3 active rulesets. No `ci.yml`. Its own `checks.yml` plus `guard-main.yml` / `guard-staging.yml`. 37 of 148 branches non-conforming |

`noble-clone`'s tier matters for sequencing, not for design: it is the one repo that will *gain* a
gate rather than have one replaced, and gaining a strict SCA gate on a tree that has never been
scanned is how a migration PR goes red on its first run for entirely legitimate reasons.

---

## Section 1 — Tag strategy

Consumers reference `Avenue-Z/repo-template/.github/workflows/checks.yml@v1`.

`v1` is a **moving major tag** that advances on every backward-compatible change. That is the whole
propagation mechanism: a fix lands on `main` here and reaches all 11 consumers with no PR anywhere.
Breaking changes cut `v2`, and consumers bump one line at their own pace.

### Breaking is exactly three things

Nothing else is. Writing the list down is what makes the `v1`/`v2` distinction enforceable rather than
a judgement call made under deadline pressure:

1. **Any change to either job name.** Because the context is `<caller>/<called>` (established fact 1),
   renaming either half renames the check — and a required check that no longer reports does not fail
   a PR, it hangs it PENDING FOREVER. This is the same failure `template-tests.yml`'s header and
   `checks.yml:11-17` already warn about, now reachable from a different direction.
2. **A new `input:` or `secret:` with no default.** Existing callers do not pass it and fail to start.
3. **A new failure condition unrelated to the caller's own content** — tightening the default SCA tier
   is the canonical example. It turns green repos red without them having changed anything. Note the
   asymmetry: a gate that gets *stricter about the caller's own code* (a new secret pattern that
   catches a key the caller actually committed) is not breaking — it is the gate working. The
   distinction is whether the caller could have caused the change in verdict.

### How `v1` moves, and why it must be protected

A workflow on `main`, gated on `template-tests` passing (see §4). **No human ever moves `v1` by
hand.**

This repo's only ruleset is `avenue-z-branch-protection`, `"target": "branch"` — verified. **Tags are
therefore entirely unprotected today**, and anyone with push access can force-move `v1` to any commit
in any repo. That is acceptable for a tag nobody consumes. It is not acceptable for a tag that eleven
private repos execute as their *only* security gate on GitHub Free. Add a **tag ruleset on `v1`**
(non-fast-forward + restricted updates) in the same change that first cuts it. Without it this design
converts a distributed-but-frozen fleet into a fleet with a single unprotected supply-chain root.

### Immutable point tags are the rollback story

Cut `v1.0.0`, `v1.1.0`, … alongside each `v1` advance, and never move them. This is not
bookkeeping — **it is the only way a consumer can respond when `v1` breaks their repo.** Without a
point tag, "pin to the last good version" has no argument to give: the previous `v1` is gone, the
consumer would have to pin to a raw SHA dug out of the reflog, and in practice they will instead
delete the caller and lose the gate. A rollback path that requires archaeology is not a rollback path.

## The org-wide branch matrix

Standardised across the org, with **no per-repo override**. A per-repo config file was considered and
rejected (see Rejected): the value here is convention *coherence*, and a repo that can quietly widen
its own matrix has opted out of the one control the fleet shares. It is also simpler for
less-experienced contributors, who currently only have to learn one rule.

**Nine prefixes:** `feat/ fix/ docs/ chore/ ci/ dependabot/ perf/ refactor/ test/`

The first six are today's list in `scripts/check-base-branch.sh:18`. `perf/` has 2 real uses in the
fleet; `refactor/` and `test/` are conventional-commit types added pre-emptively, on the reasoning
that a contributor who reaches for a legitimate conventional-commit type and is refused learns that
the guard is arbitrary rather than that their branch is wrong.

Three deliberate exclusions, each of which was wanted at some point and is wrong:

- **`security/` — excluded.** It was wanted during design and was the wrong call. The change that
  prompted it was a dependency bump, whose correct commit type is `fix(deps):` and therefore whose
  correct branch is `fix/`. The guard caught it. **The right response to a guard catching you is to
  conform, not to widen the guard** — and a prefix that exists only to accommodate one mislabelled
  branch teaches the fleet that the matrix is negotiable.
- **`feature/` — must be rejected, with a message that names the correction.** It is the single most
  common near-miss (6 branches). Rejecting it silently and rejecting it with *"use `feat/`, not
  `feature/`"* cost the same to implement and differ entirely in whether the contributor's next push
  succeeds.
- **`revert/` — excluded, and no `revert-*` exemption either.** GitHub's Revert button generates
  `revert-<PR#>-<branch>` — **a hyphen, not a slash** — so adding `revert/` to the case statement
  would not catch the thing it was added for. Making the button work would require exempting
  `revert-*` from the base-branch check entirely, and on Free this guard is the *only* enforcement for
  9 private repos. That is a named, documented bypass of the sole control, purchased to save a rename.
  **Reverts are done manually, as `fix/` branches.**

Adding a prefix later is backward-compatible and advances `v1`. Removing one is breaking and cuts
`v2` — it turns existing green branches red without the caller having changed anything, which is
exactly clause 3 above.

### The guard's error message becomes the authoritative statement of the matrix

`scripts/check-base-branch.sh:25` currently ends with:

> `Need a new prefix? Add it to the case statement in scripts/check-base-branch.sh (and to the matrix in CONTRIBUTING.md).`

**Once the script is central, that file does not exist in the contributor's repo.** The message would
be instructing them to edit a path they cannot see, in the one moment they are already confused. It
must instead point at a PR against `Avenue-Z/repo-template`.

The second half needs the same treatment for a subtler reason. Each generated repo carries its own
copied `CONTRIBUTING.md`, and those copies will drift from the central list the first time a prefix is
added — nine files saying six different things, with nothing to reconcile them. So **the guard's error
output becomes the authoritative statement of the matrix**, and each repo's `CONTRIBUTING.md` should
defer to it rather than restate it. A contributor who hits the guard reads the truth; a contributor
who reads `CONTRIBUTING.md` reads a pointer to the truth. That is a strictly better arrangement than
nine restatements that are individually plausible and collectively wrong.

---

## Section 2 — The checkout split

`actions/checkout` inside a reusable workflow resolves to the **caller** (assumed, documented, **OPEN**
here — see above). Without deliberate handling, this design would centralise the *workflow file* and
leave every *gate script* behind in each repo's stale copy — propagating the 40 lines of YAML and none
of the ~400 lines of bash that actually make the decisions. That is the shape of a migration that
looks complete and delivers nothing.

Three sources, each for a different reason:

| From | What | Why |
|---|---|---|
| `repo-template@v1` → `RUNNER_TEMP` | `check-base-branch.sh`, `sca-gate.sh`, `ci-aggregate-gate.sh` | Shared decision logic. Pinned, tag-protected, and **not writable by the PR author** |
| Caller, PR head → workspace | The tree gitleaks and osv-scanner scan | It is what is under review |
| Caller, PR head | `.github/sca-policy.json` | Per-repo tier. Stays per-repo — a client-facing repo and an internal one legitimately differ |

**This replaces the entire `.trusted-base` dance.** Today `checks.yml:76-98` checks out the caller's
base branch into `.trusted-base/`, `install`s two scripts out of it into `RUNNER_TEMP`, then
`rm -rf .trusted-base` *before* any scanner runs — because `osv-scanner scan -r ./` walks the whole
filesystem, and a stale copy of the base branch's manifests left in the workspace would fail the very
PR that fixes a vulnerable dependency (`checks.yml:66-69` says exactly this).

Checking out `repo-template@v1` into `RUNNER_TEMP` is strictly better on both counts:

- **More trustworthy.** The trust root moves from *the caller's own mutable base branch* to *a
  protected tag in a repo the PR author may not be able to push to at all*. The current design already
  concedes its own limit — the base branch is only as trustworthy as whoever can push to it.
- **No timing hazard.** `RUNNER_TEMP` is outside `GITHUB_WORKSPACE`, so the `rm -rf`-before-scanning
  ordering constraint disappears rather than being re-implemented. A correctness property that
  currently depends on step order becomes a property of where the files live.

### A gap this closes for free — flag as a finding, not a proven bug

In the current `checks.yml`, **two of the three gate scripts are trusted-staged and the third is not**:

```
line  96:  install .trusted-base/scripts/check-base-branch.sh  -> RUNNER_TEMP     trusted
line  97:  install .trusted-base/scripts/ci-aggregate-gate.sh  -> RUNNER_TEMP     trusted
line 227:  scripts/sca-gate.sh osv.json .github/sca-policy.json                   PR head tree
```

By line 227 the workspace has been re-checked-out to the PR's own tree (`checks.yml:118-124`). So a PR
can rewrite `scripts/sca-gate.sh` to `exit 0`: the step records `success`, and the verdict step —
which by design reads only step *outcomes*, never re-derives them — passes. The workflow's own comments
describe this attack in detail as the reason the other two scripts are staged
(`checks.yml:82-90`: *"a PR could rewrite it to `exit 0` and neuter the guard, the secret scan and the
SCA gate in one line"*), and then line 227 does not apply the remedy to the third script.

**Present this to the maintainer as a finding to confirm, not as a decided bug.** It may be an accepted
trade-off — the argument for it would be that the SCA verdict is less load-bearing than the base-branch
guard, and that `sca-gate.sh` reads a policy file the PR also controls anyway, so staging the script
without also staging the policy closes half a door. That argument is worth hearing before it is
overruled. What is not in doubt is that **the §2 design closes it at zero marginal cost**: all three
scripts come from the template, from the same protected tag, in the same step.

### Dual triggers — a silent-failure path that must not be missed

`init-repo.sh` ships `checks.yml` verbatim (established fact 8). **If `checks.yml` becomes
`on: workflow_call` only, a newly generated repo would carry a workflow with no triggers.** It would
never run. It would enforce nothing, produce no error, emit no annotation, appear in the Actions tab as
a workflow that simply has no runs — and it would **pass `test_init_repo.sh:46` unchanged**, because
that assertion only checks the file exists. Every repo scaffolded after this change would ship
ungated, and the test suite would report green.

That is the worst available failure shape: silent, total, and covered by a test that says otherwise.

The fix is that the workflow declares **both roles**:

```yaml
on:
  workflow_call:          # consumers call it
  pull_request:           # and it still guards repo-template itself
    types: [opened, edited, reopened, synchronize]
  schedule:
    - cron: "0 6 * * 1"
```

`workflow_call` alongside `pull_request` is legal and is the standard shape for a workflow that is both
a consumable and a live gate in its own repo. It also has a second benefit worth stating: **this
repo's own check context stays literally `checks`**, because its `pull_request` runs are ordinary
top-level jobs, not calls. `repo-template`'s own `avenue-z-branch-protection` ruleset keeps working
untouched. Only *consumers* see the renamed `checks / checks`.

And `init-repo.sh` must **write a caller, not keep the copy**. `test_init_repo.sh:46` inverts: instead
of asserting the file survived, it asserts the generated `checks.yml` **contains
`uses: Avenue-Z/repo-template/.github/workflows/checks.yml@v1`** and **does not contain
`workflow_call`**. The second half is the one that matters — it is the assertion that would have caught
the silent failure above, and it is worthless if only the first half is written.

### The caller file

```yaml
name: checks
on:
  pull_request:
    types: [opened, edited, reopened, synchronize]
  schedule:
    - cron: "0 6 * * 1"
permissions:
  contents: read
jobs:
  checks:
    uses: Avenue-Z/repo-template/.github/workflows/checks.yml@v1
```

No `with:`, no `secrets: inherit` (established fact 3). The resulting context is **`checks / checks`**.
Pick that name once and never change it — under §1's clause 1 it is the single most expensive string
in this design.

### The required-context consequence, which reaches further than it first appears

`.github/rulesets/repo-ruleset.json:34-40` requires the status check context **`checks`**, baked in
rather than added conditionally, and `checks.yml:11-17` explains why it is baked in and what happens if
it is renamed without the ruleset in the same commit. **The caller reports `checks / checks`, so that
entry is wrong the moment a repo migrates.**

On the 9 private repos this is inert (established fact 2) — the ruleset cannot be applied at all on
Free, so the JSON is a shipped artifact describing an intent, not a live control. On `data-contract`
and `avenue-z-reporting-v2` it is live and it hangs PRs pending forever. Two consequences:

- The template's shipped `repo-ruleset.json` must be updated in the **same change** as the workflow
  split (Phase A), so that no future `init-repo.sh` run produces a repo whose ruleset requires a
  context its workflow cannot report — a landmine armed today and detonating whenever the org upgrades
  to Team (see Out of scope).
- For `data-contract`, the rename and the ruleset update must land **together**, not in sequence. This
  is called out again in §3 Phase E because it is the one migration step whose wrong ordering produces
  an unmergeable repo rather than a confusing red check.

### Two limitations to state plainly

1. **Triggers cannot propagate.** A `workflow_call` workflow cannot define `on:` for its consumers, so
   the `pull_request` types and the weekly cron live in **each caller's** file. Changing the audit
   schedule later is 11 PRs. This is inherent to the mechanism, not a shortcoming of the design, and it
   sets a natural boundary on how much of the governance surface this approach can centralise: the
   *decisions* propagate, the *triggering* does not.
2. **The self-modification hole changes shape rather than closing.** Actions still reads the workflow
   file from the PR head, so a PR can still neuter its own gates — `SECURITY.md` and `checks.yml:71-74`
   already say so. But the attack gets **subtler**: previously it meant rewriting a 262-line
   `checks.yml` in a way a reviewer would notice at a glance; now it is changing `@v1` to
   `@my-branch` on one line of a nine-line file. Same hole, materially easier to miss in review.
   **`.github/` being code-owned goes from good practice to load-bearing**, and that sentence belongs
   in `SECURITY.md`, not only here.

---

## Section 3 — Migration order

| Phase | Repos | Exit criteria |
|---|---|---|
| **0** | — | **Billing restored.** Blocks everything |
| **A** | `repo-template` | `template-tests` green; `v1` cut and tag-protected |
| **B** | `data-warehouse` (pilot) | A good PR goes green; a deliberately bad PR goes red **for the right reason**; `actions/checkout` resolution settled empirically; real per-job durations measured |
| **C** | `client-satisfaction-report` | Largest consumer; migrate once B has answered the open questions |
| **D** | `announcement-recapping`, `az-media-hits`, `az-utm-generator`, `dash-social-connection`, `rippling-asana-pto`, `sf-sb-automation` | Mechanical |
| **E** | `noble-clone`, `data-contract` | See below — each has a specific hazard |
| **F** | `avenue-z-reporting-v2` | Separate project. Out of scope here |

### Why `data-warehouse` is the pilot

Three properties, and it is the only repo with all three:

- **It is a byte-identical adoption.** All six governance files match `repo-template@main` exactly,
  plus `sca-policy.json`, all three gate scripts, and `.github/rulesets`. **Any behaviour change
  observed after migration is therefore caused by the migration and nothing else** — which is the
  entire value of a pilot and is unavailable in a repo that has drifted.
- **It is private,** so rulesets are inert (established fact 2), no status check is required, and a bug
  produces a confusing red check rather than an unmergeable repo. The pilot's failure mode is
  embarrassment, not an outage.
- **It is one of the two largest consumers,** so the savings land inside the pilot and the measurement
  in §5 is taken on a repo that matters.

Two adjustments because it is busy (~30 active branches): **iterate on one throwaway PR, not on
`dev`**, and **tell whoever is working in there before flipping.** A pilot that surprises its
maintainer gets reverted on reflex, and the data is lost with it.

### Phase A checklist

1. `checks.yml` → dual triggers + the §2 checkout split
2. Nine-prefix list in `check-base-branch.sh`; **fix the now-lying error message**
3. `.github/rulesets/repo-ruleset.json` required context updated for the caller shape (see §2)
4. `init-repo.sh` writes a caller, not a copy
5. `test_init_repo.sh:46` inverted — asserts `uses: …@v1` **and** asserts no `workflow_call`
6. `v1` tag + tag ruleset + the advance workflow (§4) + immutable point tags
7. Companion PR to `Avenue-Z/claude-marketplace` (below)
8. `CONTRIBUTING.md` + `docs/ADOPTION.md`: governance changes require a companion marketplace PR

### Phase E specifics

- **`noble-clone` gains a strict SCA gate it has never had.** It has no `.github/sca-policy.json`, so
  `sca-gate.sh` fail-safes to `client-facing` (established fact 7) — the strictest tier — on a
  dependency tree that has never been scanned. **It will very likely go red on its first run, with
  real findings.** That is the gate working, and it is also exactly how a migration acquires a
  reputation for breaking things. **Warn its owner before opening the PR**, and treat the first red as
  the start of a conversation about the tier rather than as a migration defect.
- **`data-contract` is public with an active ruleset.** The `checks` → `checks / checks` rename must
  land **in the same change** as the ruleset update. In either order as separate PRs, there is a
  window in which the required context cannot be reported and **every PR in the repo hangs pending
  forever** — including the PR that would fix it.

### The marketplace dependency

`Avenue-Z/claude-marketplace` ships the `repo-template-first` skill, which names the old workflows in
four places that go stale:

| Location | Content |
|---|---|
| `plugins/repo/skills/repo-template-first/SKILL.md:3` (frontmatter) | names `guard-base-branch`, `secret-scan` — **this is the trigger description**, so edits here affect how reliably the skill fires at all |
| `SKILL.md:65` | "a private repo's real controls are `guard-base-branch` + `secret-scan`" |
| `SKILL.md:89` | "the `guard-base-branch` workflow …; `secret-scan` (gitleaks) on every PR" |
| `plugins/repo/.claude-plugin/plugin.json:3` | plugin description names `secret-scan` |

**All four are invalidated by the collapse already sitting on `dev`, the moment it reaches `main` —
independent of this work.** This design adds a fifth change: what a generated repo *contains* becomes
"a caller pointing at `@v1`", not a self-contained workflow. And `SKILL.md:59`'s reasoning about
`apply-rulesets.sh` and the `ci` context now extends to the renamed `checks / checks`.

Note the frontmatter edit is the delicate one: it is the trigger description, so a careless rewrite
degrades *when the skill fires*, not merely what it says once fired.

The skill is a **third copy** of these conventions, after the template and the 11 repos. This design
closes template↔repo drift and does nothing about template↔skill drift. At this size that is the right
call — a mechanism to sync a documentation skill with a workflow file would cost more than the drift
does — but it must be recorded rather than left implicit: **`CONTRIBUTING.md` carries an explicit line
that governance changes require a companion marketplace PR.**

---

## Section 4 — Gating a `v1` advance

`v1` moves automatically. That is the feature, and it is also the risk: **an automated tag advance is
an automated fleet-wide deploy of the security gates.** Four layers, of which three can run here.

| Layer | Proves | Status |
|---|---|---|
| 1. Unit (bash) | The gate scripts make the right decisions | **Exists** — 17 suites, incl. `test_guard_matrix.sh`, `test_checks_verdict.sh` |
| 2. Wiring (self-call) | The workflow is callable at all; the happy path is green | **New** — mirror `data-contract`'s `gate-selftest.yml` |
| 3. Contract (tripwire) | The consumer-visible surface has not moved | **New** — below |
| 4. Consumer (real) | Cross-repo `@v1` resolution; a failing gate turns the *caller* red | **Phase B only** |

**`v1` advances on layers 1–3.** Layer 4 cannot gate it — see the uncovered case below.

Layer 2 inherits a constraint: **`continue-on-error` is forbidden on a `uses:` job** (established fact
5). A self-call cannot therefore assert "this job failed and that is fine" the way an ordinary step
can. The self-test is a *happy-path* test by construction, and pretending otherwise is how
`gate-selftest.yml` learned this in the first place.

### The tripwire is the key new piece

`template-tests/test_reusable_contract.sh` asserts the workflow against a checked-in golden file,
`.github/reusable-contract.json`:

- the job key is exactly **`checks`** (this is the context)
- `on:` declares `workflow_call`, `pull_request`, and `schedule`
- the declared `inputs:` / `secrets:` sets match the golden **exactly** — additions included, not just
  removals

Any change to the consumer-visible surface reddens the test. The author must then update the golden
**in the same PR**, and *that edit is the deliberate "this is v2" decision* — visible in the diff,
routable via `CODEOWNERS`, and impossible to make by accident.

This is the mechanism that converts *"remember not to break consumers"* — a discipline that lives in
one maintainer's head and lapses silently, which this repo's ShellCheck spec already identifies as the
one control class it refuses — into a failing test. It is worth being explicit that the tripwire does
**not** know whether a change is breaking. It knows the surface moved and forces a human to say. That
is the whole job.

The second assertion is the one that catches §2's silent failure a second time, from a different
angle: if someone later strips `pull_request` from `on:` while tidying the workflow into a "pure"
reusable, layer 3 goes red, independently of whether anyone remembered to keep
`test_init_repo.sh`'s inverted assertion.

### The advance workflow

`template-tests.yml` already runs `on: push: branches: [dev, staging, main]`, so the advance chains off
its result rather than re-running it:

```yaml
on:
  workflow_run:
    workflows: [template-tests]
    types: [completed]
    branches: [main]
permissions:
  contents: write
```

Guarded by `if: github.event.workflow_run.conclusion == 'success'`, then:

- **If `.github/reusable-contract.json` changed in this push → refuse to advance `v1`** and print
  *"breaking change — cut v2 manually."* The automation's response to an intentional break is to stop,
  not to guess.
- **Otherwise** move `v1` and cut the next `v1.N.0`.

`contents: write` is the only elevated permission anywhere in this design, and it exists solely to move
a tag. That is the argument for the tag ruleset in §1 being applied in the same change: the workflow
holding this token is the *only* thing that should be able to move `v1`, and a ruleset is what makes
that true rather than merely intended.

### Uncovered by construction

**The negative case at the workflow layer — "a failing gate turns the caller red" — is provable only
from a real consumer.** Established facts 5 and 6 between them close every cheaper route: a self-call
cannot prove cross-repo ref resolution, and `continue-on-error` cannot be used to catch a deliberate
failure on a `uses:` job. **Phase B covers it once, by hand, on `data-warehouse`.** After that it is
uncovered again until someone happens to write a bad PR.

A standing canary repo calling `@v1` on a schedule would close it continuously. It is an optional
follow-on, explicitly **not** a launch blocker, and it costs billed minutes in a design whose premise
is that billed minutes are scarce.

---

## Section 5 — Concurrency and job count

**Correct a natural assumption up front: `concurrency` with `cancel-in-progress` is NOT the minutes fix
here.** 99% of `ci` jobs already finish in under 60 seconds and GitHub rounds each job up to a full
minute (established fact 4), so cancelling a job at 10 seconds bills exactly the same minute as letting
it finish. It avoids cost only for runs killed *before a runner is assigned*. Anyone reading the
consumption numbers will reach for it first; it is close to free and close to worthless as a savings
measure.

Add it anyway, **for correct behaviour** — developers currently get check results from stale commits,
which is a correctness problem independent of cost. The safe form cancels PRs only:

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
```

**Never cancel on `dev`/`staging`/`main`.** A cancelled run reports `cancelled`, not `success`, and on
Team that becomes a merge blocker — the same "a check that does not report `success` is not a pass"
rule `ci-aggregate-gate.sh` applies deliberately, arriving from an unwanted direction.

### The real lever is fewer jobs per run

For `client-satisfaction-report` (5 jobs × 112 runs over the 8-day sample):

| Change | Saves (8 days) |
|---|---|
| Matrix → one Python version on PRs, full matrix on push to `dev` | 224 min |
| Fold `bandit` into the `ci` aggregate job as a step | 112 min |
| **Combined (5 jobs → 2)** | **336 of 563 (60%) ≈ 1,260/month** |

`data-warehouse` (7 jobs × 71 runs): the same two changes plus folding `typecheck` (26s) into `test`,
≈ 284 of 567. **`dbt-parse` stays** — at 74s it is real work with its own failure mode, and merging it
would trade a diagnosable check for one billed minute.

**State the trade-off honestly: dropping the matrix on PRs is a genuine coverage reduction.** A PR can
pass on 3.13 and break on 3.11, and that will now be caught at the `dev` merge rather than on the PR —
by someone who is no longer looking at that change. It is defensible for a small team where `dev` is
the integration branch and the full matrix still runs there. It is not free, and presenting it as free
is how a team ends up surprised by the first 3.11 break and blames the wrong change.

### A trap to name and reject

**`paths-ignore` for docs-only pushes.** It genuinely cuts jobs on Free, and it is the obvious next
idea after the table above. On Team it is a landmine with a delay fuse: **a path-filtered required job
never reports on a filtered push, and a required check that never reports hangs the PR pending
forever.** This is the precise failure `template-tests.yml`'s own header documents and that
`apply-rulesets.sh:89-99` exists to avoid. Rejected — and rejected *in writing here*, because the
saving is real and someone will propose it again.

---

## Section 6 — `python-ci.yml@v1` (Phases G–H, committed)

`ci.yml` propagates too. **This is deferred in sequence, not in commitment**, and it is recorded here
so the deferral does not read as an omission.

The input surface is small, because variation is only the three axes of established fact 10:

```yaml
with:
  python-versions: '["3.11","3.12","3.13"]'
  check-command: make check      # lets the 3 laggards migrate on their own clock
  run-bandit: true               # covers az-* and noble-clone until they catch up
```

Two of the three axes become inputs. **The third disappears for free, and it is the sleeper win:**
pinned action SHAs live inside the reusable workflow, so Dependabot's `checkout` / `setup-python` bumps
collapse from **11 PRs to 1**, and `@v1` carries the new pin everywhere. That eliminates a recurring
category of both drift and toil, and it is arguably worth more over a year than the minutes.

Per-repo extras still work — a workflow may freely mix `uses:` jobs with ordinary ones:

```yaml
jobs:
  standard:
    uses: Avenue-Z/repo-template/.github/workflows/python-ci.yml@v1
    with: { python-versions: '["3.11","3.12","3.13"]' }
  dbt-parse:
    runs-on: ubuntu-latest
    steps: [...]
  ci:
    needs: [standard, dbt-parse]
```

Two consequences worth stating explicitly:

- **The aggregate job stays in the caller,** so the required context remains literally `ci` — which is
  what `apply-rulesets.sh:98` registers. `python-ci.yml` therefore **avoids the rename problem that
  `checks` cannot avoid**, purely because `ci` was already an aggregate over other jobs and `checks`
  was not. That asymmetry is worth understanding rather than treating as luck.
- **The §5 job-count reduction lives inside the reusable workflow,** so it propagates by construction
  instead of being hand-ported into 10 repos and then hand-ported again the next time it changes.

**Sequencing rationale:** after Phase B, because designing a second reusable workflow before the first
has run in production even once is the wrong order of risk — every open question in §2 is equally open
for `python-ci.yml`, and answering them twice is waste. If Phase G follows Phase B closely, **the §5
interim fix becomes optional**: the job-count reduction is ported into callers once rather than twice.

| Phase | Work |
|---|---|
| **G** | `python-ci.yml` reusable, with the §5 job-count reduction inside it, cut as `@v1` |
| **H** | Migrate the 10 repos' `ci.yml` to callers |

---

## Open items

Recorded as open, not as decided:

1. **The two unverified mechanics** (see Step 0): private→public reusable-workflow **execution**, and
   `actions/checkout` resolution inside a called workflow. Both are Phase B's job. The design is
   written as though the documented behaviour holds; if it does not, §2 is the section that changes.
2. **Hand-porting `checks.yml` to `client-satisfaction-report` for early relief — deliberately
   deferred.** Billing is blocked, so the meter is not currently running and the urgency is
   artificial. Phase B will measure the real per-job duration on a large tree and therefore the real
   saving. **Decide after** — with a number rather than an estimate.
3. **Whether the collapsed `checks` job stays under 60 seconds on a large tree.** It now downloads
   gitleaks *and* osv-scanner and runs both scans in one job. The template measured 160 → 54 billed
   minutes on its own small tree; **if the merged job crosses 60s on a real repo the saving drops from
   ~66% to ~33%.** Phase B settles this. **Do not quote a savings figure for `checks.yml` as
   established** until it does — the 54 figure is a measurement of this repo, not of the fleet.
4. **The `sca-gate.sh` staging gap** (§2) — flagged as a finding for the maintainer to confirm or
   accept, though the §2 design closes it either way.

---

## Rejected

- **A per-repo branch-matrix config file.** It was the flexible option and it defeats the purpose: the
  value of the matrix is that it is the same everywhere, and a repo that can widen its own list has
  opted out of the only control the fleet shares on Free. It also adds a concept for every contributor
  to learn, in the one part of the system aimed at the least-experienced ones.
- **`security/` as a branch prefix.** The change that wanted it was a dependency bump —
  `fix(deps):`, therefore `fix/`. The guard was right and the branch was wrong. See §1.
- **`revert/`, and a `revert-*` exemption.** `revert/` does not match what GitHub's Revert button
  generates (`revert-<PR#>-<branch>`, hyphen), so it would not solve the problem it exists for; the
  exemption that *would* work is a named bypass of the only enforcement 9 private repos have. Reverts
  are manual `fix/` branches.
- **`concurrency: cancel-in-progress` as the minutes fix.** Adopted for correctness, rejected as a
  savings measure — per-job minute rounding makes it near-worthless for jobs that already finish in
  seconds. Included here as a Rejected item precisely because it is the first thing anyone proposes.
- **`paths-ignore` on docs-only pushes.** Real savings on Free; on Team a path-filtered required check
  hangs every PR pending forever. See §5.
- **Keeping the `.trusted-base` checkout alongside the template checkout.** Once all three gate scripts
  come from `@v1`, the base-branch copy has nothing left to supply, and retaining it would keep the
  `rm -rf`-before-scanning ordering hazard for no benefit.
- **Advancing `v1` by hand.** A human-moved tag is a human-forgotten tag, and the failure is silent:
  the fleet simply stops receiving fixes, with no red check anywhere to say so.

## Out of scope

- **`avenue-z-reporting-v2` conformance.** Public, 3 active rulesets, no `ci.yml`, its own `checks.yml`
  plus `guard-main.yml` / `guard-staging.yml`, and 37 of 148 branches non-conforming. That is a
  migration *and* a cleanup *and* a ruleset change, and folding it into this work would let the
  hardest repo set the pace for the ten easy ones. Phase F, its own project.
- **A standing canary repo** for continuous layer-4 coverage. Optional follow-on. Not a launch blocker,
  and it spends billed minutes to buy coverage that Phase B buys once.
- **Automating template↔marketplace-skill drift.** A `CONTRIBUTING.md` line instead. Three copies of a
  convention is a documentation problem at this size, not an engineering one.
- **Upgrading the org to GitHub Team.** Out of scope as a decision, but note where this design changes
  if it happens: **rulesets become live on all 12 repos.** Established fact 2 stops holding, and every
  consequence currently confined to `data-contract` and `avenue-z-reporting-v2` becomes fleet-wide —
  context renames hang PRs, `paths-ignore` hangs PRs, a cancelled run on `dev` blocks a merge. The
  design does not need to change; the **ordering discipline in Phase E does**, and it would need to be
  applied to all nine private repos rather than to two public ones.
- **Extending the propagation mechanism beyond `checks.yml` and `python-ci.yml`.** The node and next
  stacks in `templates/` have their own CI and are not addressed here.
