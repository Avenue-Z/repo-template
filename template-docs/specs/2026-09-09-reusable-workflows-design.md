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
- **Whether a consumer's default `GITHUB_TOKEN` can check out `Avenue-Z/repo-template` at all.** This
  is a *second* access path and the bullet above does not cover it. Resolving and executing a reusable
  workflow from another repository is one permission; `actions/checkout` cloning that repository from
  inside the run — which is what §2's script staging does — is another. `GITHUB_TOKEN` is scoped to the
  repository whose run it belongs to, and cross-repository clones with it are governed by org Actions
  policy rather than by the template's own settings. **This is the single assumption the whole design
  rests on and it has not been tested even partially.** If it fails, §2 needs a credential this design
  does not currently have, and the answer changes what §1's tag protection is protecting.
  **Phase B probe:** one job in `data-warehouse` — `actions/checkout` with
  `repository: Avenue-Z/repo-template`, `ref: v1`, `path: .trusted-template`, the default token, then
  `ls .trusted-template/scripts`. Yes or no, in one billed minute.
- **Whether `github.job_workflow_ref` is empty on a NON-called run, or is populated equal to
  `github.workflow_ref`.** §2's staging step refuses when that context is empty in a repository that is
  not the template, and its comment calls that state "impossible". If the context is instead populated
  on a direct run, the refusal never fires and the failure moves one step later, to a checkout of a ref
  that does not exist in `repo-template`. Still fail-closed either way — but the maintainer sees
  "ref not found" instead of the message written for them, which is the difference between a two-minute
  diagnosis and an afternoon. **Phase B probe:** echo `github.job_workflow_ref` from an ordinary
  `pull_request` job and from a called one, in the same run.
- **Whether a fork PR whose head branch is literally named `main` reaches the advance workflow.**
  §4's `workflow_run` trigger filters on `branches: [main]`, and that filter matches the *head branch*
  of the upstream run. A fork PR from a branch called `main` therefore satisfies it. The ancestry check
  refuses such a SHA correctly — it sits before the acknowledged short-circuit — but the checkout fails
  first, so the visible result is a red `advance-v1` on somebody else's fork PR. Noise rather than a
  hole, and worth confirming rather than assuming. **Phase B probe:** open a PR from a fork branch
  named `main` and watch whether `advance-v1` is queued at all.

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
   The same addition **with** a default is backward-compatible and advances `v1` — but never silently.
   It still moves the golden contract file, so §4's tripwire still refuses the automatic advance and a
   maintainer has to acknowledge it in the open. See §4's acknowledgement path; the two sections would
   otherwise contradict each other, with §1 calling a change non-breaking and §4 refusing to ship it.
3. **A new failure condition unrelated to the caller's own content** — tightening the default SCA tier
   is the canonical example. It turns green repos red without them having changed anything. Note the
   asymmetry: a gate that gets *stricter about the caller's own code* (a new secret pattern that
   catches a key the caller actually committed) is not breaking — it is the gate working. The
   distinction is whether the caller could have caused the change in verdict.

### How `v1` moves, and why it must be protected

A workflow on `main`, gated on `template-tests` passing (see §4). **No human ever moves `v1` by
hand.** (Cutting it the first time is Phase A's job and is done once, by hand, because there is nothing
for the advance workflow to move yet. The rule is about every advance after that.)

This repo's only ruleset is `avenue-z-branch-protection`, `"target": "branch"` — verified. **Tags are
therefore entirely unprotected today**, and anyone with push access can force-move `v1` to any commit
in any repo. That is acceptable for a tag nobody consumes. It is not acceptable for a tag that eleven
private repos execute as their *only* security gate on GitHub Free. Add a **tag ruleset on `v1`**
(non-fast-forward + restricted updates) in the same change that first cuts it. Without it this design
converts a distributed-but-frozen fleet into a fleet with a single unprotected supply-chain root.

**The ruleset must not lock out the workflow that moves the tag.** A ruleset applies to `GITHUB_TOKEN`
like any other actor, and this repo's house pattern is `"bypass_actors": []` —
`.github/rulesets/repo-ruleset.json:15` ships exactly that. Written that way, the tag ruleset would
block §4's advance workflow: `contents: write` is a token permission, and a ruleset is a separate,
higher control that the permission does not satisfy. The tag ruleset therefore carries **one bypass
actor: the GitHub Actions app** (`"actor_type": "Integration"`; the app's numeric id is looked up at
apply time rather than written down here from memory). It targets `refs/tags/v1` exactly, so the
immutable `v1.N.0` point tags fall outside it and their creation needs no bypass at all.

That keeps the default `GITHUB_TOKEN` sufficient and **adds no secret** — established fact 3 stays
true. A fine-grained PAT or a dedicated GitHub App was the alternative and is Rejected below: it buys a
tighter bypass at the price of a long-lived credential to store and rotate in a repo that today needs
none.

The residual belongs in the open rather than in a footnote: **the bypass is repo-scoped, not
workflow-scoped.** Any workflow in `repo-template` that requests `contents: write` inherits the ability
to move `v1`, not just the advance workflow. Today there would be exactly one, and adding a second is a
change to `.github/`, on a PR, in the repo whose entire subject is this gate. Recorded in
`## Open items`.

### Immutable point tags are the rollback story

Cut `v1.0.0`, `v1.1.0`, … alongside each `v1` advance, and never move them. This is not
bookkeeping — **it is the only way a consumer can respond when `v1` breaks their repo.** Without a
point tag, "pin to the last good version" has no argument to give: the previous `v1` is gone, the
consumer would have to pin to a raw SHA dug out of the reflog, and in practice they will instead
delete the caller and lose the gate. A rollback path that requires archaeology is not a rollback path.

**This only works if the gate scripts travel with the tag.** A point tag is a rollback for the
*workflow file*; it is not one for the ~400 lines of bash that make the decisions unless the staging
step inside the workflow resolves *its own* version rather than a hardcoded ref. Written the obvious
way — `ref: v1` in the script checkout — a consumer pinned to `checks.yml@v1.2.0` would still execute
gate scripts staged from the moving `v1`: the rollback would restore the YAML and leave the behaviour
it was rolled back from fully in place. That is worse than having no rollback, because it looks like
one and reports success. §2 resolves the ref from `github.job_workflow_ref` for this reason, and that
mechanism is what makes this section true rather than aspirational.

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

`scripts/check-base-branch.sh:24` currently ends with:

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
| `repo-template`, **at the ref this workflow was called at** → `RUNNER_TEMP` | `check-base-branch.sh`, `sca-gate.sh`, `ci-aggregate-gate.sh` | Shared decision logic. Pinned, tag-protected, and **not writable by the PR author** |
| Caller, PR head → workspace | The tree gitleaks and osv-scanner scan | It is what is under review |
| Caller, PR head | `.github/sca-policy.json` | Per-repo tier. Stays per-repo — a client-facing repo and an internal one legitimately differ |

### "The ref this workflow was called at" is a specific context, and the wrong one looks right

The value is **`github.job_workflow_ref`**, which holds the ref path of the *called* workflow — e.g.
`Avenue-Z/repo-template/.github/workflows/checks.yml@refs/tags/v1.2.0`. The staging step takes
everything after the last `@` and checks the template out at that ref.

`github.workflow_ref` — the name that reads more naturally and is the one an author reaches for
first — holds the **caller's** top-level workflow and is the wrong value here. And a literal `ref: v1`
is worse than either: it would make §1's immutable point tags a rollback for the YAML only, with the
gate scripts still staged from the moving `v1`. Deriving the ref from the workflow's own identity is
what keeps `checks.yml@v1.2.0` and the scripts it runs the same version of the same thing.

### The staging dance is inherited, not solved

**This replaces `.trusted-base` on the consumer path.** Today `checks.yml:76-98` checks out the
caller's base branch into `.trusted-base/`, `install`s two scripts out of it into `RUNNER_TEMP`, then
`rm -rf .trusted-base` *before* any scanner runs — because `osv-scanner scan -r ./` walks the whole
filesystem, and a stale copy of the base branch's manifests left in the workspace would fail the very
PR that fixes a vulnerable dependency (`checks.yml:66-69` says exactly this).

Changing where the staged scripts come from improves the trust root. It does **not** remove the dance:

- **More trustworthy.** The trust root moves from *the caller's own mutable base branch* to *a
  protected tag in a repo the PR author may not be able to push to at all*. The current design already
  concedes its own limit — the base branch is only as trustworthy as whoever can push to it.
- **The `rm -rf`-before-scanning ordering constraint stays, and an earlier draft of this section was
  wrong to say otherwise.** That draft reasoned that `RUNNER_TEMP` is outside `GITHUB_WORKSPACE` and
  concluded the hazard disappears. The first half is true of `RUNNER_TEMP` and false of the step that
  fills it: **`actions/checkout`'s `path:` is documented as a path *under* `GITHUB_WORKSPACE`**, and it
  will not write outside it. So the shape is unchanged — check the template out into a workspace
  subdirectory (`.trusted-template/`), `install` the three scripts into `RUNNER_TEMP`, delete the
  subdirectory before any scanner runs — and only the *source* changes. Anyone editing that step must
  keep the `rm -rf` ahead of the scanners for exactly the reason it is there today.

### repo-template's own runs, and the bootstrap

Everything above is the **consumer** path. This repo's own `pull_request` runs must not take it, for
two independent reasons:

1. **Bootstrap.** Phase A cannot cut `v1` until `template-tests` is green, and `template-tests` cannot
   be green if every PR's `checks` job checks out a tag that does not exist yet. Specified as
   `@v1`-for-everyone, the first PR of Phase A is red on account of a tag that PR exists to create —
   including the PR that would fix it.
2. **A self-PR would be judged by the released copy of the script it is changing.** A PR that fixes
   `check-base-branch.sh` would run the *previous* `check-base-branch.sh`, so the change under review
   is never exercised by the run reviewing it. The one repo where that matters most is the repo that
   owns the script.

So the staging step branches on **`github.repository`**: in `Avenue-Z/repo-template` the scripts come
from the workspace; everywhere else they come from the ref in `github.job_workflow_ref`. Inside a
called workflow `github.repository` is the *caller's* repository, which is exactly the discriminator
wanted, and it is documented behaviour rather than an inference about whether some other context
happens to be empty when unset.

**State the cost, because it is real.** On this repo's own PRs the guard is once again supplied by the
PR it judges — the hole `checks.yml:60-74` exists to close, reopened on `repo-template` alone. Two
things blunt it and neither closes it: `template-tests` runs on the same PR and `test_guard_matrix.sh`
asserts the matrix behaviour directly, so a `check-base-branch.sh` rewritten to `exit 0` turns a
**required** context red; and this repo is public, so the diff is visible. A PR that edits a script and
its suite together defeats both. Recorded in `## Open items` as an accepted risk scoped to this repo,
rather than presented as covered.

### A gap this partly closes — flag as a finding, not a proven bug

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
without also staging the policy closes half a door.

**That last argument survives the §2 design, so the honest claim is "partly closes", not "closes at
zero marginal cost".** The script half is real and is free: all three scripts come from the template,
from the same ref, in the same step. The policy half is not closed at all. `.github/sca-policy.json` is
per-repo *by design* — it is the third row of the table above — so it still arrives from the PR head,
and the tier it carries is a dial the PR can turn. `"tier": "internal"` makes `sca-gate.sh` warn-only
in every case (`sca-gate.sh:11-12`), and the same file is the SAST dial too: `bandit-gate.sh` reads
`.tier` from it and `internal` is warn-only there as well (`sca-gate.sh:18-20` records the sharing;
`bandit-gate.sh:12` is the behaviour). So a PR that can no longer neuter the script can still neuter
the verdict, by editing one JSON field instead of rewriting the script the staging was added to
protect — a *smaller* diff than the attack §2 closes, not a larger one.

Nothing in this design closes that, and both candidate remedies cost something this document has not
priced: staging the policy from the caller's base branch reintroduces the `.trusted-base` checkout for
a single file, and moving the tier to a repository variable puts it out of PR reach but is a new
mechanism that has to be set by hand in 11 repos and has no fail-safe when it is unset.
**Recorded in `## Open items`, undecided.**

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

### What happens to `scripts/` in a generated repo

This has to be answered explicitly, because the natural reading of "the gate scripts come from the
template now" is that generated repos stop carrying them — and that reading bricks every one of them.

**`scripts/` stays, in full.** `init-repo.sh` never removed it: `:370` deletes `templates/`,
`template-tests/` and `template-docs/` and nothing else, and `:369` says so in as many words
("scripts/ keeps apply-rulesets.sh regardless"). The stack's own `ci.yml` invokes the local copies
directly — `templates/python/.github/workflows/ci.yml:91` runs `scripts/bandit-gate.sh` and `:101` runs
`scripts/ci-aggregate-gate.sh` — so until §6's `python-ci.yml` lands in Phase G, dropping `scripts/`
would make the **required** `ci` check fail to start in all ten repos that have one. `checks.yml:257`
does the same on this repo's own non-PR path.

What does change is that two of those scripts stop being *executed* in a migrated consumer:
`check-base-branch.sh` and `sca-gate.sh` were only ever invoked by `checks.yml`, which now stages its
own copies. `ci-aggregate-gate.sh` keeps running from the local tree because `ci.yml` still calls it
there, and `bandit-gate.sh` was never a `checks.yml` script at all.

Two inert copies in eleven repos is precisely the drift trap this design exists to remove — someone
edits one, nothing happens, and nothing explains why. **They are deleted once Phase E completes, not
before.** Through Phases A–E they are the rollback path: a consumer whose migration goes wrong restores
a self-contained `checks.yml` and its scripts are still sitting there. Once the last repo has migrated
and the two Step 0 OPEN mechanics have actually been answered, a cleanup step removes both from every
consumer and stops `init-repo.sh` shipping them — at which point `test_init_repo.sh:53` and `:55`
(`assert_file "check-base-branch.sh survived"`, `assert_file "sca-gate.sh survived"`) invert. That
cleanup is Phase E's last item and deliberately not Phase A's: it is the step that cannot be undone
cheaply.

### The caller, and what `init-repo.sh` writes

`init-repo.sh` must **write a caller, not keep the copy**. `test_init_repo.sh:46` inverts: instead
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
and `avenue-z-reporting-v2` it is live and it hangs PRs pending forever.

**And it cannot be fixed by editing the baked-in value, because that file serves two populations at
once.** `apply-rulesets.sh:78` copies `repo-ruleset.json` verbatim as the payload for whichever repo
the operator is standing in, and the comment at `:85-88` states the arrangement outright — the file is
shared by the template and by every generated repo. Under the dual-trigger design above,
`repo-template` keeps reporting literally `checks` (its `pull_request` runs are ordinary top-level
jobs) while every migrated consumer reports `checks / checks`. Baking in either name leaves the other
population requiring a context that nothing reports, which does not fail those PRs — it hangs them
PENDING FOREVER. One file cannot hold both names.

**Resolution: `checks` stops being baked in and becomes file-gated, using the mechanism the script
already has.** `apply-rulesets.sh:89-99` carries an `add_context` helper that adds `ci` and
`template-tests` only when the workflow that reports them is actually present, for this exact reason
("a required check with no workflow hangs every PR pending forever"). The `checks` decision joins them,
keyed on whether the local `checks.yml` declares `workflow_call` — true in `repo-template`, false in a
caller:

```text
checks.yml declares workflow_call        ->  require 'checks'           (repo-template itself)
the `checks` job declares a `uses:`      ->  require 'checks / checks'  (a migrated consumer)
neither                                  ->  require 'checks'           (a self-contained copy)
```

**There are three shapes here, not two, and an earlier draft of this section missed the third.** It
keyed the consumer branch on the *absence* of `workflow_call`, which is not the same question. A
**self-contained copy** of `checks.yml` — no `workflow_call`, no `uses:` — declares neither, and it is
not hypothetical: it is what all eleven repos hold today, and §2 designates it as the migration
rollback path ("a consumer whose migration goes wrong restores a self-contained `checks.yml`"). Such a
copy reports plain `checks`, but the absence-of-`workflow_call` test would have required
`checks / checks` from it. On `data-contract` or `avenue-z-reporting-v2`, where rulesets are live,
re-running `apply-rulesets.sh` after a rollback would then hang every PR pending forever — the rollback
path detonating the thing it exists to recover from. Keying the consumer branch on the **presence of a
`uses:` in the `checks` job** answers the question actually being asked, and costs a line.

One ruleset file, no new concept, and the precedent is the script's own. It is not free: the shipped
`required_status_checks` list becomes empty, so the two suites that assert its contents move with it —
`test_rulesets.sh:105-106` (`expected=$(printf 'checks')`, then `assert_eq`) and
`test_apply_rulesets.sh:31` (`assert_match "'checks' is listed as required"`). Both are named in the
Phase A checklist, in the same PR as the change that invalidates them.

The alternative — keeping the required context literally `checks` everywhere by giving each caller a
second, ordinary `checks` job that `needs:` the called one, which is the shape §6 uses to keep `ci`
literal — is Rejected below on cost: one extra billed job per PR in eleven repos, in a design whose
premise is that job count is the bill.

Two consequences remain:

- `repo-ruleset.json` **and** `apply-rulesets.sh` must change in the **same change** as the workflow
  split (Phase A), so that no future `init-repo.sh` run produces a repo whose ruleset requires a
  context its workflow cannot report — a landmine armed today and detonating whenever the org upgrades
  to Team (see Out of scope).
- For `data-contract`, whose ruleset is live, the rename and the ruleset update **cannot be made
  atomic at all** — a ruleset is not applied by merging a PR. That is a property of where rulesets
  live, not a sequencing preference, and §3 Phase E carries the ordering that is actually safe.

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
   in `SECURITY.md`, not only here. Note what that requires and does not yet have: this repo ships
   `.github/CODEOWNERS.tmpl` and only `init-repo.sh` instantiates it, so `repo-template` itself has no
   live CODEOWNERS at all, and the shipped ruleset sets `require_code_owner_review: false`
   (`repo-ruleset.json:28`). In both populations code ownership is today a convention, not a control.
   Making it load-bearing is a change to make, not a fact to cite.

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

The order matters and so does the grouping. §4 gates the `v1` advance on `template-tests` passing, so
**`template-tests` must not be red at a phase boundary** — and the §2 design invalidates six suites the
moment it lands. Items 1–6 are therefore **one PR**: the workflow change and the assertions it
falsifies cannot be separated without leaving the gate red in between, and a red gate at the end of
Phase A means Phase A cannot reach its own exit criterion.

1. `checks.yml` → dual triggers, the §2 checkout split, and the `github.repository` branch that keeps
   this repo's own PRs on a workspace checkout
2. Nine-prefix list in `check-base-branch.sh`; **fix the now-lying error message**
3. `repo-ruleset.json` drops the baked-in `checks` context; `apply-rulesets.sh` gains the file-gated
   `checks` / `checks / checks` decision (see §2)
4. `init-repo.sh` writes a caller, not a copy
5. **The suites §2 breaks, updated in the same PR as the change that breaks them.** Named individually,
   because "update the tests" as one line is how one of six gets missed:
   - `test_guard_matrix.sh:51-55` — hard-asserts, anchored, that the checkout carries
     `ref: ${{ github.base_ref }}`. On the consumer path there is no base-branch checkout at all. The
     assertion splits: the base-branch form stays asserted for the `github.repository` self-path, and
     the consumer path asserts that the guard runs from `RUNNER_TEMP`, staged at the ref in
     `github.job_workflow_ref`
   - `test_sca.sh:157` — asserts the literal `rm -rf .trusted-base`. The directory is renamed
     (`.trusted-template`), but the property worth asserting was never the name: assert that the
     staging directory is deleted **before** anything scans the tree
   - `test_sca.sh:145` — asserts `checks.yml` contains the literal string `scripts/sca-gate.sh`.
     `sca-gate.sh` is now staged and invoked from `RUNNER_TEMP` like the other two; the assertion
     follows the script, not the path it used to sit at
   - `test_rulesets.sh:105-106` — asserts the shipped ruleset's required contexts are exactly
     `{checks}`. Under item 3 the shipped list is empty and the contexts are added by the script
   - `test_apply_rulesets.sh:31` — asserts `apply-rulesets.sh` prints `required: checks`. It now prints
     one of two values depending on the local `checks.yml`. Assert **both** branches: asserting only
     the one that happens to hold in this repo is how the consumer branch ships untested
   - `test_init_repo.sh:46` — inverted: asserts the generated `checks.yml` **contains
     `uses: …/checks.yml@v1`** and **does not contain `workflow_call`**. The second half is the one
     that matters — it is the assertion that would have caught §2's silent-failure path, and it is
     worthless if only the first half is written
   - `test_checks_verdict.sh` — not known to break, and read rather than assumed before the PR opens:
     it asserts the verdict wiring that item 1 moves
6. Layer 2, the self-call, added as a job **inside `template-tests.yml`** (§4) — so that "the workflow
   is callable" sits in the run the advance chains off
7. **`v1` cut, by hand, once 1–6 are green** — plus the tag ruleset with its GitHub Actions bypass
   actor (§1), the advance workflow (§4), and `v1.0.0`. This is the one time a human touches the tag,
   and it is manual because there is nothing for the advance workflow to move yet
8. Companion PR to `Avenue-Z/claude-marketplace` (below)
9. `CONTRIBUTING.md` + `docs/ADOPTION.md`: governance changes require a companion marketplace PR

What is deliberately **not** here: deleting the now-inert `check-base-branch.sh` / `sca-gate.sh` from
generated repos. That is Phase E's last item — see §2.

### Phase E specifics

- **`noble-clone` gains a strict SCA gate it has never had.** It has no `.github/sca-policy.json`, so
  `sca-gate.sh` fail-safes to `client-facing` (established fact 7) — the strictest tier — on a
  dependency tree that has never been scanned. **It will very likely go red on its first run, with
  real findings.** That is the gate working, and it is also exactly how a migration acquires a
  reputation for breaking things. **Warn its owner before opening the PR**, and treat the first red as
  the start of a conversation about the tier rather than as a migration defect.
- **`data-contract` is public with an active ruleset, and the rename cannot be made atomic.** An
  earlier draft of this section required the rename and the ruleset update to "land in the same
  change". They cannot: **a ruleset is not applied by merging a PR.** `apply-rulesets.sh` is run out of
  band, by a person, against the GitHub API (`:148` is the `PUT`, `:152` the `POST`), so no single
  change contains both halves. The safe ordering is a sequence, and it is this one:

  1. **Drop the required context first**, while `checks` is still reporting — `PUT` the ruleset with an
     empty `required_status_checks` list. This is a hand-run `gh api` call, not
     `./scripts/apply-rulesets.sh`: with §2's file-gating the script always adds one of the two
     contexts, and mid-migration neither is correct.
  2. **Merge the caller PR.** `checks` stops reporting; `checks / checks` starts.
  3. **Re-add the context**, now `checks / checks`. From here `./scripts/apply-rulesets.sh` does the
     right thing unaided, because the local `checks.yml` is a caller.

  **Name the window: between steps 1 and 3, `main`/`staging`/`dev` in `data-contract` require no status
  check at all.** The rest of the ruleset — the pull-request requirement, `non_fast_forward`,
  `deletion` — stays in force, so this is "a PR can merge with a red or absent gate", not "anyone can
  push to `main`". Do it in one sitting, when nobody else is merging, and do not start step 1 unless
  step 3 will finish the same day.

  There is a zero-window variant, priced and not chosen: land the caller as a **second** workflow file
  alongside the existing `checks.yml` so both contexts report at once, require both, then delete the
  old workflow and drop its context. It costs one extra billed job per PR for the length of the
  overlap — affordable on one repo, and the right call if step 3 cannot be guaranteed to happen
  promptly.

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
| 1. Unit (bash) | The gate scripts make the right decisions | **Exists** — 16 suites, incl. `test_guard_matrix.sh`, `test_checks_verdict.sh` |
| 2. Wiring (self-call) | The workflow is callable at all; the happy path is green | **New** — a job *inside* `template-tests.yml`, mirroring `data-contract`'s `gate-selftest.yml` |
| 3. Contract (tripwire) | The consumer-visible surface has not moved | **New** — below |
| 4. Consumer (real) | Cross-repo `@v1` resolution; a failing gate turns the *caller* red | **Phase B only** |

**`v1` advances on layers 1–3.** Layer 4 cannot gate it — see the uncovered case below.

Layer 2 inherits a constraint: **`continue-on-error` is forbidden on a `uses:` job** (established fact
5). A self-call cannot therefore assert "this job failed and that is fine" the way an ordinary step
can. The self-test is a *happy-path* test by construction, and pretending otherwise is how
`gate-selftest.yml` learned this in the first place.

**Layer 2 has to live inside `template-tests.yml`, not beside it.** The advance chains off the
`template-tests` *workflow run* (below), so a self-call published as its own workflow would gate
nothing: `v1` could advance carrying a reusable workflow that is not callable at all, which is the one
failure this layer exists to catch. Making it a job of `template-tests.yml` puts its result inside the
run whose `conclusion` the advance reads, and costs no new wiring.

The job is gated to pushes (`if: github.event_name == 'push'`) rather than running on every PR. That is
a cost decision — one extra billed job per push instead of one per PR — and it should be honest about
what it buys: on a `push` event the called workflow takes its non-PR path, so the self-call proves the
workflow **resolves, expands and runs green**, and does not exercise the base-branch guard or the
PR-scoped secret scan. Layer 1 covers those. `if:` is permitted on a `uses:` job even though
`continue-on-error` is not — the same constraint from established fact 5, seen from the other side.

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
concurrency:
  group: advance-v1
  cancel-in-progress: false
```

The `concurrency` group is not decoration and it is the one place in this design where §5's advice is
inverted. Two merges landing close together produce two advance runs, and `git push --force` on a tag
does not care which commit is newer: if the *older* run finishes last, **`v1` moves backward** and the
fleet silently runs an older gate, with no red check anywhere to say so. `cancel-in-progress: false` is
equally deliberate — §5 cancels superseded PR runs because a stale result is noise, but a cancelled
*advance* is a missed propagation, which is the failure this whole document exists to remove.

Guarded by `if: github.event.workflow_run.conclusion == 'success'`. Two mechanics inside it are easy to
get wrong and silent when wrong.

**It must check out the commit that was actually tested.** A `workflow_run`-triggered run does not
default to the commit that triggered the upstream workflow: GitHub documents `GITHUB_SHA` for
`workflow_run` as the last commit on the **default branch**, and `GITHUB_REF` as the default branch
itself. Two merges in quick succession therefore put the second one's tip in the workspace while the
first one's result is what succeeded — and `v1` would be tagged onto a commit `template-tests` never
ran against. The checkout is explicit about it:

```yaml
- uses: actions/checkout@<pinned>
  with:
    ref: ${{ github.event.workflow_run.head_sha }}
    fetch-depth: 0
```

`fetch-depth: 0` is not decoration; the next mechanic needs history and tags.

**"Files changed in this push" has no source in the payload, and the obvious substitute is not
sticky.** The `workflow_run` payload carries `head_sha` and `head_commit` but **no commit list and no
changed-file set**, so "did `.github/reusable-contract.json` change in this push?" has to be computed
rather than read. Computing it against the *previous commit* is both unavailable here and wrong on its
own terms, because the refusal would be **one-shot**: a breaking commit lands and the tripwire refuses;
the next unrelated push touches nothing in the contract file, passes, and advances `v1` **straight past
the breaking commit**. The refusal would protect exactly one push and then evaporate.

So the comparison is against **what `v1` currently points at** — the only base that makes the refusal
persist:

```bash
git fetch --tags --force
base="$(git rev-parse -q --verify refs/tags/v1^{commit})" || refuse "v1 does not resolve"
changed="$(git diff --name-only "${base}" "${GITHUB_SHA}" -- .github/reusable-contract.json)"
```

- `changed` non-empty → **refuse to advance**, printing *"the consumer contract has changed since
  `v1` — cut `v2`, or acknowledge this as additive."* Because the base does not move until `v1` does,
  the refusal now holds across every subsequent push until a human acts.
- `changed` empty → move `v1` to `GITHUB_SHA` and cut the next `v1.N.0`.
- **The comparison cannot be made** — `v1` does not resolve, the fetch failed, `git diff` errored →
  **refuse, loudly.** "I could not tell" is not "nothing changed", which is the same posture
  `apply-rulesets.sh:57-62` takes toward a plan lookup it cannot perform.

**The acknowledgement path, which §1 clause 2 requires.** §1 calls a new input **with a default**
backward-compatible, but the tripwire is an exact match on the golden file, so an additive input moves
that file and lands in the refusal branch above. With no way out, the design would declare additive
changes non-breaking and then behave as though they were not. The `workflow_dispatch` above is the way
out: a maintainer re-runs the advance naming the SHA, and it moves `v1` and cuts the point tag on the
normal path with the contract comparison skipped. Both properties that mattered survive — **the tag is
still moved by the workflow, never by a person at a keyboard**, and a human still has to state in the
open that the surface moved. The only thing that changes is that the answer to "the surface moved" can
be *"yes, additively"* as well as *"cut v2"*.

**One constraint the escape hatch must carry, or it is not an escape hatch — it is a bypass.** Written
as "a `workflow_dispatch` skips the comparison", the acknowledgement path skips *everything*: the
tripwire and the `v1`-resolution refusal both. That was the shape this document described, and driving
it proved what it costs — an unmerged, contract-breaking, never-tested SHA returns "advance", and so
does a branch name like `main`, which tags whatever `main` happens to be at dispatch time rather than
what was tested. The effective policy becomes: **any account with write access can point `v1` at any
commit in the repository**, using the very Actions-app ruleset bypass §1 introduced to stop exactly
that. A control that converts its own protection into a general-purpose "point `v1` anywhere" button is
not a control.

So the dispatched SHA is constrained before anything else happens:

```bash
git merge-base --is-ancestor "${TARGET_SHA}" origin/main || {
  echo "::error::${TARGET_SHA} is not an ancestor of main — refusing to point v1 at it"; exit 1; }
```

`git merge-base --is-ancestor` exits 0 for an ancestor, 1 for a non-ancestor, and other non-zero codes
for a genuine error — a malformed SHA, a missing object. All three of the latter are refusals here,
which keeps the same posture as the rest of this section: "I could not tell" is never "go ahead".

This narrows the hatch to what it was for — shipping an **additive** contract change without cutting
`v2` — and leaves one thing it still does not do: it confirms the SHA is *on `main`*, not that
`template-tests` ever passed on it. Closing that needs a `gh api` lookup of the run conclusion for the
dispatched SHA, which is a new external dependency. Recorded in `## Open items` rather than assumed.

`contents: write` is the only elevated permission anywhere in this design, and it exists solely to move
a tag. That is the argument for the tag ruleset in §1 being applied in the same change: the workflow
holding this token is the *only* thing that should be able to move `v1`, and a ruleset — with the
GitHub Actions bypass actor that lets this workflow through and nobody else — is what makes that true
rather than merely intended.

### Uncovered by construction

**The negative case at the workflow layer — "a failing gate turns the caller red" — is provable only
from a real consumer.** Established facts 5 and 6 between them close every cheaper route: a self-call
cannot prove cross-repo ref resolution, and `continue-on-error` cannot be used to catch a deliberate
failure on a `uses:` job. **Phase B covers it once, by hand, on `data-warehouse`.** After that it is
uncovered again until someone happens to write a bad PR.

A standing canary repo calling `@v1` on a schedule would close it continuously. It is an optional
follow-on, explicitly **not** a launch blocker, and it costs billed minutes in a design whose premise
is that billed minutes are scarce.

**§1's clause-3 breaks are uncovered too, and by a wider margin.** A new failure condition unrelated to
the caller's own content — tightening the default SCA tier is the canonical example — moves no job
name, adds no input and edits no golden file. It passes layers 1, 2 and 3 with nothing to say, and `v1`
carries it to eleven repos on the next push to `main`. Layer 1 would catch it only if someone had also
written the test that pins the *old* behaviour as required, which is exactly the
discipline-in-one-maintainer's-head control this repo's ShellCheck spec refuses to rely on — and the
control the tripwire was built to replace for clauses 1 and 2.

Nothing here catches it, and building something that would — a golden file over gate *behaviour* rather
than gate *surface* — is a larger piece of work than this design contains. It is therefore a **named
accepted risk**, recorded in `## Open items`, with the only two things that genuinely reduce it stated
as what they are and no more: the `dev → staging → main` flow gives such a change a soak on two
branches before it reaches the tag, and §1's three clauses are written down, so "is this clause 3?" is
a question with an answer rather than a matter of taste.

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

**Never cancel on `dev`/`staging`/`main` — and `cancel-in-progress: false` is not enough to guarantee
that.** A cancelled run reports `cancelled`, not `success`, and on Team that becomes a merge blocker —
the same "a check that does not report `success` is not a pass" rule `ci-aggregate-gate.sh` applies
deliberately, arriving from an unwanted direction.

The trap is that `cancel-in-progress` governs only runs that are already *in progress*. GitHub's
documented behaviour is that when a run enters a concurrency group, any **pending** run already queued
in that group is cancelled regardless of the flag. Two pushes to `dev` in quick succession, with the
first still queued behind a busy runner pool, therefore still produce a `cancelled` conclusion under
the form above — which is precisely the merge blocker this section claims to avoid.

The fix is to keep branch pushes out of a shared group at all, so there is never a pending run to
cancel, rather than to ask the group not to cancel one:

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.event_name == 'pull_request' && github.ref || github.sha }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
```

On `pull_request` the group is the ref and superseded runs are cancelled, which is the behaviour that
was wanted. On a push the group is the commit SHA, so every push is alone in its group and neither the
in-progress nor the pending rule can reach it. This follows from the documented semantics — a
concurrency rule only ever affects runs that share a group — and it has **not** been measured here;
the Phase B run that answers everything else should watch for a `cancelled` conclusion on `dev`.

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

1. **The three unverified mechanics** (see Step 0): private→public reusable-workflow **execution**,
   `actions/checkout` resolution inside a called workflow, and whether a consumer's default
   `GITHUB_TOKEN` can check out `Avenue-Z/repo-template` at all. All three are Phase B's job. The
   design is written as though the documented behaviour holds; if it does not, §2 is the section that
   changes.
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
   accept. The §2 design closes the *script* half of it either way.
5. **The `.github/sca-policy.json` half, which §2 does not close** (§2). The gate scripts move to a
   trusted ref; the tier dial they read does not. It is a one-line edit in the PR's own head that turns
   the SCA verdict — and the SAST verdict, which shares the file — warn-only. Two candidate remedies,
   neither priced: stage the policy from the caller's base branch (reintroduces `.trusted-base` for a
   single file), or move the tier to a repository variable (out of PR reach, but a new mechanism to set
   by hand in 11 repos, with no fail-safe when unset). **Undecided.**
6. **`repo-template`'s own PRs supply the scripts that judge them** (§2). The deliberate consequence of
   keeping this repo's `pull_request` runs on a workspace checkout, so that a PR changing a gate script
   is actually exercised by the run reviewing it — and so that the PR cutting Phase A is not red for
   failing to check out a tag Phase A has not cut yet.

   **This is a REDUCTION against what shipped in PR #59**, and it is the one security delta in the
   reusable-workflow change. Under #59 all three gate scripts were staged from the BASE branch, out of
   the PR's reach. They now come from the workspace — the PR head — so on this repo a PR can rewrite
   `check-base-branch.sh`, `sca-gate.sh` or `ci-aggregate-gate.sh` to `exit 0` and its own run executes
   that version. With `required_approving_review_count: 0`, nobody is obliged to look.

   **The compensating control is `template-tests`, and its limit is exact.** It runs on the same PR and
   `test_guard_matrix.sh` asserts the branch matrix directly, so a lone `exit 0` rewrite turns a
   REQUIRED context red. A PR that edits the script *and* its suite in the same change defeats it.
   Code ownership is not available as the second control that would catch that: this repo has no live
   `.github/CODEOWNERS`, and the shipped ruleset sets `require_code_owner_review: false`.

   **Consumers are strictly stronger, not weaker.** All eleven get their scripts from the immutable tag
   via `github.job_workflow_ref`, entirely out of reach of the PR under review. The weakening is scoped
   to the one repo that cannot bootstrap any other way.

   **Accepted risk, scoped to this repo**, on the grounds that the alternative is a template that cannot
   change its own gate. Revisit if `.github/CODEOWNERS` ever goes live here, which would make
   `require_code_owner_review` a real second control over `scripts/`.
7. **Clause-3 breaks reach the fleet ungated** (§1, §4). A behaviour change that alters no declared
   surface passes all three gating layers and auto-deploys on the next push to `main`. No mechanism
   here catches it. **Accepted risk**, reduced only by the `dev → staging → main` soak and by §1's
   clauses being written down.
8. **The `v1` tag bypass is a dedicated GitHub App, and the residual is its secret** (§1). What this
   item used to accept — a repo-scoped bypass, where any workflow requesting `contents: write` could
   move `v1` — **is moot, because the mechanism it described does not exist.** The rulesets API refuses
   the GitHub Actions app as a bypass actor (`Actor GitHub Actions integration must be part of the
   ruleset source or owner organization`): it is not an installable app and never appears in an org's
   installations. The bypass is a dedicated app instead; `advance-v1.yml` mints a one-hour token from
   its private key and GITHUB_TOKEN drops to `contents: read`. That is **strictly stronger** than the
   original: `contents: write` no longer moves the tag, so a second writer in `.github/workflows/` is
   no longer a concern.

   **The residual moves to the secret.** Repository secrets are readable by any workflow in the repo,
   so a workflow that names `V1_TAG_APP_PRIVATE_KEY` can mint the same token — and adding one is still
   a change to `.github/` that has to pass the PR gate and reach `main`. The unpriced hardening is an
   `advance-v1` **environment** holding the two secrets, with its deployment branches restricted to
   `main`, which would make the credential unobtainable from a workflow running anywhere else.
   **Accepted, with the environment recorded as the next step if this ever matters.**
9. **Two inert scripts in every migrated consumer, until Phase E's cleanup** (§2).
   `check-base-branch.sh` and `sca-gate.sh` keep shipping through Phase E as the rollback path. Until
   they are deleted, editing either has no effect and produces no error — the drift trap this design
   exists to remove, deliberately kept for the length of the migration. **Time-boxed, not permanent.**
10. **Whether the `data-contract` cutover takes the windowed or the overlap ordering** (§3 Phase E).
    The windowed one leaves `main`/`staging`/`dev` without a required status check between two
    out-of-band ruleset edits; the overlap one costs an extra billed job per PR while both workflows
    report. **Decide when the cutover is scheduled, on who is available to finish it the same day.**
11. **The acknowledgement path confirms the dispatched SHA is on `main`, not that it was ever tested**
    (§4). The ancestry check closes the "point `v1` anywhere" hole; it does not establish that
    `template-tests` concluded `success` for that commit. Closing it needs a `gh api` lookup of the run
    conclusion for the SHA — a new external dependency inside the one workflow holding
    `contents: write`, and a new failure mode when the API is unreachable ("I could not ask" would have
    to refuse, which makes the escape hatch itself outage-sensitive). **Undecided**, and deliberately
    not built as part of Phase A.
12. **The self-call couples fleet-wide propagation to the template's own dependency tree** (§4 layer 2).
    The self-call runs `checks.yml` on the `push` path, where there is no base ref — so every push to
    `main` performs a full-history secret scan and a full `osv-scanner scan -r ./` of the tree,
    `templates/` included. Its result is part of the `template-tests` run whose conclusion gates the
    tag. **A new advisory published against any dependency in `templates/` therefore halts propagation
    of security fixes to all eleven repos**, with the only signal a red run on `main`. It fails closed,
    and the `workflow_dispatch` hatch can move `v1` past it. That hatch now documents this case
    explicitly, alongside the additive-contract-change one, in `advance-v1.yml`'s `on:` block and in
    the dispatch input's own description — an operator who meets this reads the escape on the form
    they are already looking at. **Accepted for Phase A**, because the alternative is exempting the
    template's own tree from its own gate. Revisit if it ever actually fires.

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
  come from the called workflow's own ref, the base-branch copy has nothing left to supply. It would
  not buy back the `rm -rf`-before-scanning ordering constraint either — that is inherited by the
  template checkout, because `actions/checkout` can only write under `GITHUB_WORKSPACE` (§2).
- **A second, ordinary `checks` job in every caller, to keep the required context literally `checks`.**
  It is §6's shape, and it would delete the rename problem outright — including Phase E's unprotected
  window and the Team-upgrade landmine below. One extra billed job per PR across eleven repos is too
  much to pay for it in a design whose premise is that job count is the bill. Recorded rather than
  dropped, because it is the right answer if the org ever leaves Free. See §2.
- **A PAT or a dedicated GitHub App to move the `v1` tag.** Tighter than bypassing the tag ruleset for
  the GitHub Actions app, and it costs a long-lived credential to store and rotate in a repo that today
  needs none (established fact 3). See §1.
- **Splitting `repo-ruleset.json` into one file per population.** It would duplicate the ruleset's
  other four rules and create a second drift surface — the thing this design exists to remove. The
  file-gated `add_context` in §2 reaches the same place with one file and the script's own precedent.
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
