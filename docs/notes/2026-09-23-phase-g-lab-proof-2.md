# Phase G lab proof 2: a skipped required check, and the caller against the tag (2026-09-23)

Two lab measurements for Avenue-Z/repo-template#88 and #90. Every lab PR was closed unmerged.

## Part A: a required job skipped because a need failed counts as PASSING (#90)

**Why a new repo.** `avenue-z-ci-lab` is on the Free plan, and every repo in it but one is private, so
none of them can hold a ruleset. A required check cannot be measured without one. The measurement
was taken in a new **public** repo, `avenue-z-ci-lab/required-check-probe`. Being public, it also runs
Actions for free.

**Setup.** Ruleset `23894392` (`require-ci`) on `~DEFAULT_BRANCH`, one rule:
`required_status_checks` with the single context `ci`, strict policy off. `ci.yml` on each PR head has
two jobs: `work` (`run: exit <0|1>`) and `ci`, which `needs: [work]` and runs the template's jq verdict.
Only the `ci` job's `if:` and `work`'s exit code vary.

| PR | `work` | `ci` job's `if:` | `ci` conclusion (required) | `mergeStateStatus` | Mergeable despite a failing job? |
|---|---|---|---|---|---|
| #1 control | success | `always()` | success | `CLEAN` | n/a |
| #2 | **failure** | **none** | **skipped** | **`UNSTABLE`** | **yes** |
| #3 | failure | `always()` | failure | `BLOCKED` | no |
| #4 | success | `github.event_name == 'push'` | skipped | `CLEAN` | n/a |

`isRequired` was read per check run through GraphQL on each PR: `ci` was the required check every
time. `UNSTABLE` is GitHub's "mergeable, with non-passing checks that are not required". `BLOCKED` is
what a failing required check produces.

**Conclusion.** GitHub treats a required check whose job was **skipped** as satisfied. That holds
whether the job was skipped by its own `if:` (#4, the case GitHub documents) or because a job it
`needs` failed (#2, the case that was open). So a `ci` aggregate without `if: always()` does not hang
a PR: it lets a PR with a failing `work` job **merge**. That is a false green, not a pending forever.

The comments that say otherwise are wrong, and have been since before Phase G:

- `templates/python/.github/workflows/ci.yml` on `dev` (the inline template): "a skipped required
  check never reports either — it blocks the merge just as silently as a missing one."
- `templates/python/.github/workflows/ci.yml` on #88 (the caller): "a skipped required check never
  reports."

`if: always()` itself is correct, and the shipped templates carry it. What's wrong is the reason
given, and `scripts/apply-rulesets.sh` has no refusal for a hand-written `ci` job that leaves it out.
Both are #90.

Runs: #1 `35902609618`, #2 `35902613803`, #3 `35902620943`, #4 `35902625703`.

## Part B: the shipped caller against `@python-ci-v1` itself (#88)

The first lab proof (`2026-09-22-phase-g-lab-proof.md`) ran the caller at `@feat/python-ci-reusable`
(`b38190c`). `python-ci-v1` points at `f6a1146`, which adds `0212a3a` (Bandit refuses a scan that
covered nothing). These runs close that gap. Each PR replaced `avenue-z-ci-lab/adopter-python`'s
`ci.yml` with the Python template's caller exactly as it stood at `0bf9538`, targeting `dev`.

| Case | Lab PR | `ci` run | `ci` | Verdict / error, from the log |
|---|---|---|---|---|
| Good PR | #15 | 35902797055 | **green** | `every needed job succeeded` |
| Failing test (`assert False`) | #16 | 35902804777 | **red** | `the 'check' job did not succeed (result: failure)` |
| Python in `lib/`, not `src/` | #17 | 35902811841 | **red** | `bandit: scan target(s) not found: ./src — refusing to report an unscanned tree as clean`; `the 'bandit' job did not succeed` |

All three logged `gate scripts: staging from Avenue-Z/repo-template@refs/tags/python-ci-v1` from the
OIDC `job_workflow_ref` claim, so the tag's scripts ran, not a workspace copy.

**The `lib/` case named the wrong refusal in our own docs.** #88's `0642c11` told adopters that a repo
without `src/` gets "bandit scanned 0 lines of code". It gets `scan target(s) not found: ./src`, from
`bandit-gate.sh:44`. The 0-lines refusal (`:49`) is for a `src/` that exists but holds no Python.
Corrected in `8daefb2`.

`checks / checks` was red on all three, **for an unrelated reason**: the branch guard rejects the
`probe/` prefix (`Unrecognized branch prefix 'probe/g2-good'. This guard FAILS CLOSED.`). The first
lab proof used `feat/` branches. The next lab run should too.

## Durations (job start → completion)

For #91's `timeout-minutes` sizing.

| Run | `python-ci / test (3.11)` | `ci` |
|---|---|---|
| 35902797055 (good) | 17s | 3s |
| 35902804777 (failing test) | 18s | 4s |
| 35902811841 (no `src/`) | 17s | 3s |

In line with the first proof (19–25s / 3–5s).
