# Dependabot coverage for the template's starter manifests — design

## Why this exists

`.github/dependabot.yml` declares one ecosystem: `github-actions` at `/`. The starter manifests
under `templates/` — two `package-lock.json` files and one `pyproject.toml` — are watched by
nothing.

Those manifests are **payload**. `init-repo.sh` copies them verbatim into every repo created from
this template, so a stale dependency there is not one stale dependency; it is one per repo anyone
creates, inherited at birth and carried until someone notices.

Today the only thing that notices is the `sca` gate, and it notices **reactively**, after a
High/Critical advisory with an available fix has already landed. That has happened twice in under a
month:

| Date | Commit / PR | What it looked like |
|---|---|---|
| 2026-07-31 | c0eecd7 | `brace-expansion`, `postcss`, `sharp` — an unrelated PR went red |
| 2026-08-24 | #54 | `nanoid`, `js-yaml` — blocked the `dev` → `staging` promotion in #50 |

Both times the symptom was identical: a PR about something else turned red, and a human did an
unplanned dependency bump under time pressure to unblock it. Neither was caught by the deps being
watched, because they are not watched. The `sca` gate did its job perfectly — it is a **gate**, not
a maintenance schedule, and it fires at the worst possible moment by design.

This converts that fire-drill into a routine weekly PR.

## This is a different blind spot from the actions one — and unlike that one, it is fixable

Worth stating so the two are not conflated by whoever reads this next.

For the **`github-actions`** ecosystem, Dependabot scans the root `.github/workflows` only. It
cannot be pointed at `templates/*/.github/workflows/ci.yml`, and `test_action_pins.sh` documents at
length that no configuration fixes this — which is why the answer there was a lockstep *test* that
converts silent rot into a failing check.

For **npm and pip**, Dependabot does scan nested directories. So this blind spot is closable by
configuration, and a lockstep test would be the wrong instrument.

## Scope, and an asymmetry worth being honest about

Three entries, but they are not motivated equally:

- **`/templates/node` and `/templates/next` (npm)** — real vulnerability exposure. These two
  `package-lock.json` files are the only things `osv-scanner` actually extracts in this repo (419
  and 176 packages respectively; its filesystem walk reports "2 Extract calls"). Every finding the
  `sca` gate has ever produced came from here.
- **`/templates/python` (pip)** — hygiene, not vulnerability management. The python starter is a
  `pyproject.toml` with no lockfile, so it contributes **nothing** to `osv-scanner` today and has
  never appeared in an `sca` finding. Its value is keeping the `ruff` / `mypy` / `pytest` floors
  current for every generated Python repo, which is worth having but is a different claim.

If the weekly volume proves annoying, **the python entry is the one to drop first.** Recorded here
so that decision is a re-reading of this trade-off rather than a fresh argument.

## The generated-repo problem, and the mechanism

`init-repo.sh` runs `rm -rf templates` at generation. If these entries were plain additions, every
generated repo would ship a `dependabot.yml` pointing at three directories that no longer exist.

So the block is **sentinel-delimited** in the core file:

```yaml
  # >>> TEMPLATE-ONLY — watches the starter manifests under templates/. scripts/init-repo.sh
  # deletes everything between these markers at generation, because templates/ is deleted too.
  # Do not remove the markers; init-repo.sh refuses to run without them.
  - package-ecosystem: npm
    directory: "/templates/node"
    schedule: { interval: weekly }
    target-branch: dev
    open-pull-requests-limit: 5
    groups:
      non-major:
        update-types: [minor, patch]
  # ... the same entry shape for npm at /templates/next and pip at /templates/python
  # <<< TEMPLATE-ONLY
```

`init-repo.sh` deletes between the markers **before** `add_dependabot_ecosystem` appends the
selected stack's block, and **fails closed if the markers are absent** — the same posture the script
already takes with `vercel.json` ("require exactly `false` and fail closed otherwise"). A missing
marker means the file is not the file this script was written against, and guessing at that point is
how a generated repo ends up with a broken config.

**Why not rewrite `dependabot.yml` wholesale at init** (the obvious alternative): it would duplicate
the `github-actions` block into a heredoc inside `init-repo.sh`, leaving two definitions of the core
ecosystem free to drift. **Why not delete by matching `directory: "/templates`**: it makes the
deletion depend on incidental formatting of a line rather than on an explicit contract, and it
silently no-ops if the shape ever changes. The markers are a contract, and they are testable.

## Noise control

Each entry uses a `groups:` block to collapse non-major updates into **one PR per directory per
week**; majors stay separate, because a `next` or `vitest` major is a decision, not a bump.
`open-pull-requests-limit: 5` matches the existing entry.

Nothing is auto-merged. There is no automerge anywhere in this repo and this does not introduce it.

## Two external facts to verify empirically, not assume

Following the precedent set by the SCA plan — which handled an uncertain external fact with an
explicit verification step rather than a guess — these are **observations to make, not claims this
spec makes**:

1. **Does Dependabot's `pip` ecosystem update a hatchling PEP-621 `pyproject.toml` whose dev tools
   live in `[project.optional-dependencies]`?** Dependabot's pip support is best documented for
   `requirements.txt` and Poetry. If the first cycle produces nothing for `/templates/python`, the
   entry is inert and should be removed rather than left as decoration.
2. **Do the grouped PRs actually open against `dev`?** `target-branch: dev` is set, and
   `guard-base-branch` fails closed on any prefix not in the allowed list — `dependabot/*` is in it,
   as #47 demonstrated, but confirm rather than infer.

Observe the first cycle before treating either as settled.

## Wiring

| File | Change |
|---|---|
| `.github/dependabot.yml` | Add the sentinel-delimited three-entry block with `groups:`. |
| `scripts/init-repo.sh` | Delete between the markers before `add_dependabot_ecosystem`; die if markers absent. |
| `template-tests/test_init_repo.sh` | Assert the generated file: has the stack ecosystem at `/`, contains no `/templates` directory, retains no markers. |
| `template-tests/test_init_repo.sh` | Assert `init-repo.sh` **dies** when the markers are missing (drive it against a mutated copy). |

## Testing

1. **Generated-repo shape** — after a real `init-repo.sh` run for each of the three stacks, the
   resulting `dependabot.yml` declares `github-actions` plus exactly one stack ecosystem, mentions
   `/templates` nowhere, and carries no sentinel markers.
2. **Fail-closed, verified red.** Strip the markers from a scratch copy and confirm `init-repo.sh`
   exits non-zero with an explanatory message. This assertion is the whole point of the mechanism,
   so it must be observed failing, not assumed.
3. **The core file's block is well-formed and findable.** Assert each marker appears exactly once,
   opener before closer, and that every line between them is either a comment or a correctly
   indented list entry. Asserted structurally rather than by parsing: the suite has `jq` and
   `python3`, but PyYAML is not guaranteed on the runner and the tool assertion in
   `template-tests.yml` does not claim it.
4. Full suite green before push, as with every change here.

## What this does NOT do

- **It does not make template dependency bumps safe to merge.** CI validates the *structure* of the
  templates; it never runs `npm ci && make check` against `templates/node` or `templates/next`. Both
  bumps this month were validated by hand, including the `next build` that `test_next_stack.sh` does
  not perform. Dependabot will now open these PRs *more often*, which makes the gap more visible —
  it is real, it is named here, and it is separate work.
- **It does not replace the `sca` gate.** Dependabot version updates and vulnerability blocking are
  different jobs. The tiered policy in `sca-policy.json` remains the control that decides what
  blocks a merge.
- **It does not change what a generated repo watches.** A new repo still gets exactly one ecosystem
  block for its own stack, as it does today.

## Rejected

- **Renovate instead of Dependabot.** A whole second update system, plus a third-party app with
  repo write access, to solve a problem three lines of existing-tool configuration solve.
- **A lockstep test in the style of `test_action_pins.sh`.** Right instrument for the actions
  blind spot because that one cannot be configured away. Wrong here: it would assert templates match
  some external notion of "current" with nothing to compare against, and it would go red on a
  schedule nobody chose.
- **Watching `templates/*/package.json` for majors with auto-merge.** No automerge in this repo.

## Out of scope

- Running `npm ci && make check` against the template directories in CI — the named gap above. Its
  own spec.
- Any change to `sca-policy.json`, its tiers, or `sca-gate.sh`.
- Dependency coverage for `template-docs/` or the repo's own tooling.
