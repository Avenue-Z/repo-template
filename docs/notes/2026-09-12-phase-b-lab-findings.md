# 2026-09-12 — Phase B findings, measured outside Avenue-Z

Avenue-Z's Actions minutes are exhausted org-wide, so the design's Step 0 blocks Phase B on
`data-warehouse`. These mechanics were settled instead in a **throwaway org**, `avenue-z-ci-lab`,
whose billing is independent. Everything below was **observed**, with run ids.

**Why the results transfer.** The lab calls `Avenue-Z/repo-template` (or a public lab template) from a
**private repo in a different org** — a *stricter* arrangement than the real fleet, which is same-org.
A green result here is strong evidence for Avenue-Z; a red one might be cross-org-specific. The
failure direction is the safe one.

## Scoreboard

| Open mechanic (spec Step 0) | Answer | Evidence |
|---|---|---|
| #1 A private repo can execute a public template's reusable workflow | **Yes** | `ci-probe` ran a cross-org call to completion |
| #2 `actions/checkout` inside a called workflow resolves to the **caller** | **Yes — as the design assumed** | run `34708273212` |
| #3 A consumer's default `GITHUB_TOKEN` can clone `Avenue-Z/repo-template` | **Yes** | run `34705640335` |
| #4 `job_workflow_ref` is empty on a non-called run | **Yes on a non-called run — and empty on a CALLED one too** | runs `34705640335`, `34705912086` |
| #5 What a caller missing `id-token: write` actually does | **`startup_failure`, no context reported — not a red check** | runs `34709355618`, `34709404243` |

## THE FINDING — §2's staging mechanism does not work as written

`github.job_workflow_ref` is **not populated in the `github` expression context at all** — called or
not. `checks.yml` reads it to decide which ref of the template to stage gate scripts from, so **every
consumer's gate dies at the first step**:

```
##[error]github.job_workflow_ref is empty and this is not repo-template — refusing to stage gate scripts from an unknown ref
##[error]the trusted verdict script is missing — refusing to report a verdict
```

Observed on a real generated adoption (`avenue-z-ci-lab/adopter-private` PR #1, run `34705802136`),
then reproduced with no Avenue-Z involvement at all in `ci-probe` (run `34705912086`):

```
PROBE workflow_ref     = [avenue-z-ci-lab/ci-probe/.github/workflows/caller.yml@refs/heads/main]
PROBE job_workflow_ref = []
PROBE job_workflow_sha = []
```

**It fails CLOSED, and that is the design working.** `checks.yml:129` calls the empty state
"impossible" and refuses rather than guessing a ref. Had it guessed, eleven repos would have run a
gate staged from somewhere arbitrary and reported green. The instinct to refuse converted a silent
fleet-wide compromise into a loud, immediate stop.

## THE FIX — the value exists, in the OIDC token

`job_workflow_ref` is an **OIDC claim**, not a `github` context field. That distinction is almost
certainly what produced the bug. Run `34708273212`, a private lab repo calling a public lab template
cross-org:

```
CLAIM job_workflow_ref: avenue-z-ci-lab/probe-template/.github/workflows/probe-reusable.yml@refs/heads/main
CLAIM workflow_ref:     avenue-z-ci-lab/ci-probe/.github/workflows/cross.yml@refs/heads/main
CLAIM repository:       avenue-z-ci-lab/ci-probe
RESULTC: PRESENT
```

The claim carries **exactly** the value §2 needs — the called workflow's own ref — and it is visibly
distinct from `workflow_ref`, which holds the caller's. Point-tag rollback therefore still works:
pinned at `@v1.2.0`, the claim reads `refs/tags/v1.2.0`.

**Cost:** the caller must grant `permissions: id-token: write`. Like `on:`, that lives in the caller
and can never propagate — but it lands in the same migration PR that writes the caller anyway.

**An earlier version of this line said a repo that omits it "gets a gate that refuses rather than one
that silently passes." That was an assumption, it was wrong, and the real shape is worse — see the
next section.**

**Residual worth naming:** `id-token: write` lets the called workflow mint OIDC tokens for *any*
audience, so every consumer hands the template a small privilege-escalation surface. First-party code,
remote risk, but real.

## THE COST IS NOT A REFUSAL — it is a check that stops reporting

Measured after the fix was written, by dropping the grant on purpose in `adopter-private` and putting
it back. **A caller that omits `id-token: write` does not get the refusal above. It gets nothing.**

| Run | Caller grants | Result |
|---|---|---|
| `34709404243` | `contents: read` + `id-token: write` | `checks / checks` **success**, all three scanners ran |
| `34709355618` | nothing (workflow-level `contents: read` only) | **`startup_failure`, zero jobs, no context reported at all** |

`checks.yml` requests `id-token: write`; a caller granting less is an **elevation**, and permissions
along a call chain can be maintained or reduced but never elevated. GitHub rejects that when it
expands the call — *before* any job exists. So the run dies at startup, `checks / checks` is never
reported, and the `gh api .../check-runs` listing for that SHA contains only `ci`.

**A required check that never reports does not fail a PR. It hangs it PENDING FOREVER.** That is the
exact failure mode §2 spends a page avoiding, reached by a different road: not a renamed context, an
absent one. It is loud in the Actions tab and invisible on the PR.

Two consequences for §3's ordering, both sharper than "put it in the migration PR":

- On `data-contract` and `avenue-z-reporting-v2`, where rulesets are **live**, the grant must be
  merged *before* `apply-rulesets.sh` requires `checks / checks` there. Getting that order wrong
  bricks the repo rather than reddening a PR.
- On the 9 private repos the ruleset is inert (established fact 2), so the same mistake is merely a
  gate that never runs — which is what the fleet already has today, and is why it could go unnoticed.

**The same rule caught `repo-template` itself.** `template-tests.yml`'s `self-call` job is a caller and
is bound by it too. Adding the permission to `checks.yml` without adding it there killed the whole
`template-tests` workflow at startup (run `34709475980`) — and `if: github.event_name == 'push'` did
**not** save it, because the call is expanded before the condition is evaluated, so `pull_request`
runs died as well, on a **required** check. If the self-call had been the only place this was wrong it
would have been caught by CI; it is recorded here because the reasoning ("the `if:` means it only
matters on push") is the plausible wrong answer.

**Alternative not taken, worth knowing exists.** Dropping `checks.yml`'s `permissions:` block entirely
would make the called workflow inherit the caller's grant, turning that startup failure into the
graceful red refusal — at the price of giving this repo's own runs whatever the org-default
`GITHUB_TOKEN` scope happens to be, which `checks.yml:74-79` deliberately closes. Recorded as a trade,
not decided here.

## Options considered and not taken

- **Inline the gate logic into `checks.yml`** — deletes the problem, but throws away the idiom the 19
  suites are built on (they drive the shipped `scripts/*.sh`; the ShellCheck gate covers `scripts/`,
  not inline `run:` blocks). **No minutes benefit either:** jobs bill rounded up to a whole minute, so
  shaving clone seconds saves nothing. **Rejected.**
- **Generate the scripts into the workflow, lockstep-asserted** (the `test_action_pins.sh` idiom) —
  architecturally the strongest: zero runtime trust decisions, because GitHub already delivered the
  logic at the pinned ref. Keeps every suite working. **Recorded as the direction**, not done now: it
  is a rewrite of the most security-critical file, justified by elegance rather than by minutes, and
  the fleet is waiting.
- **Hardcode `ref: v1`** — defeats point tags exactly as silently as the design already warned.
- **Pass the ref as a caller input** — forgeable, and two strings that drift.

## Also confirmed

- **The context name is `checks / checks`**, observed on a real consumer. `apply-rulesets.sh` would
  have required the right string.
- **`init-repo.sh` produces a correct adoption**: a nine-line caller, with `reusable-contract.json`
  and `advance-v1.yml` stripped.
- **The generated repo's own `ci.yml` is a full copy, not a caller** — so the stack pipeline still does
  not propagate. See §6, and `2026-09-12`'s trigger change.

## The lab

| Repo | Role |
|---|---|
| `avenue-z-ci-lab/ci-probe` (private) | Probes. `caller.yml` → local self-call; `cross.yml` → cross-org call |
| `avenue-z-ci-lab/probe-template` (public) | Hosts `probe-reusable.yml`; carries `MARKER-template.txt` |
| `avenue-z-ci-lab/adopter-private` (private) | A real `init-repo.sh` adoption. The end-to-end regression environment |

Keep them until §2 is fixed and validated. They cost nothing idle, and `adopter-private` is where the
fix should be proven before any Avenue-Z repo sees it.

## Still open

1. **Real per-job durations**, and therefore the §5 savings figure. Needs a large tree on a billed
   repo. Do **not** quote a savings number for `checks.yml` as established.
2. **Layer 4's second half** — a *deliberately bad* PR going red **for the right reason** on a real
   consumer. The good-PR path is now **closed**: with the fix pinned in, `adopter-private` PR #8 ran
   `check-base-branch.sh`, gitleaks (1 commit, no leaks) and osv-scanner (176 packages,
   `tier: client-facing`) and reported `checks / checks` green (run `34709404243`). The **bad**-PR
   half is still untested — nothing has yet been observed going red for the right reason on a
   consumer.
3. **Avenue-Z's org Actions policy is unread** (`admin:org` scope needed). The lab runs default policy,
   so #3's "yes" is a yes *under default policy*.
