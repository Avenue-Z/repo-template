# Phase G lab proof — python-ci.yml in avenue-z-ci-lab/adopter-python (2026-09-22)

Plan Task 6 of `template-docs/plans/2026-09-22-reusable-workflows-phase-g.md`, for
Avenue-Z/repo-template#84. The lab repo's `ci.yml` was replaced with the Task 8 caller, with the `uses:`
ref pointed at `@feat/python-ci-reusable` (branch head `b38190c`). Every PR targeted `dev` and was
closed unmerged afterwards. Lab billing is separate from Avenue-Z's.

## Results

| Case | Lab PR | `ci` run | Expected | Observed |
|---|---|---|---|---|
| Good PR, `["3.11"]` | #10 | 35746415176 | `ci` green, 2 jobs, scripts staged from the branch | **green**; jobs `python-ci / test (3.11)` + `ci`; log: `gate scripts: staging from Avenue-Z/repo-template@refs/heads/feat/python-ci-reusable` |
| Failing test (`assert False`) | #11 | 35746556117 | `ci` red, verdict names `check` | **red**; `the 'check' job did not succeed (result: failure)`, `ok: 'bandit' succeeded`; `ci` verdict: `python-ci: failure` |
| Bandit B602 (`subprocess.Popen(c, shell=True)`), tier `client-facing` | #12 | 35746561964 | `ci` red, B602 HIGH/HIGH, verdict names `bandit` | **red**; `B602 HIGH/HIGH src/app/main.py:9`, `ok: 'check' succeeded`, `the 'bandit' job did not succeed (result: failure)` |
| Caller without `id-token: write` | #13 | 35746567094 | `startup_failure`, zero jobs, no `ci` context | **startup_failure, 0 jobs**; the PR shows only `checks / checks` — `ci` never reports |
| Library shape `["3.11","3.12","3.13"]` | #14 | 35746570913 | 3 legs, Bandit only in 3.11, `ci` green | **green**; three `test` legs; in 3.12 and 3.13 both Bandit steps are `skipped` and the verdict gates `check` only |

The startup_failure row is the silent failure that plan Task 9 guards against: a required `ci` would
hang the PR PENDING FOREVER, with no red check to explain why.

## Durations (job start → completion, from the run's job timestamps)

These feed spec §5's still-open 60-second question. B confirms it on real repos.

| Run | `python-ci / test` | `ci` |
|---|---|---|
| 35746415176 (good) | 21s | 3s |
| 35746556117 (failing test) | 19s | 4s |
| 35746561964 (B602) | 21s | 5s |
| 35746570913 (library) | 25s / 21s / 21s | 4s |

Both jobs finish well under a minute. Billing rounds each one up to a full minute, so a Python PR now
costs 2 billed minutes where the inline `ci.yml` cost 4 (3 matrix legs + `ci`).

## The tag cut and its protection (plan Task 7, Steps 4–5; 2026-09-23)

**Recorded here because the ruleset lives only in the GitHub API** (spec Open item 18). This note is
the only place the change can be reviewed.

**Cut by hand, once**, from `main` at `f6a1146` (the promotion merge of #87; `template-tests` run
35768182668 concluded `success` on exactly that SHA):

| Tag | Kind | Points at |
|---|---|---|
| `python-ci-v1` | lightweight, moving | `f6a1146` |
| `python-ci-v1.0.0` | annotated point tag (`5ab9869`) | `f6a1146` |

Until then `advance-v1` refused on every push to `main`: run 35768242424's `python-ci-v1` row
failed with `python-ci-v1 does not resolve`, as designed.

**Ruleset `22951344` (`v1-tag-protection`), `conditions.ref_name.include`:**

| Before | After |
|---|---|
| `["refs/tags/v1"]` | `["refs/tags/v1", "refs/tags/v1.*", "refs/tags/python-ci-v1", "refs/tags/python-ci-v1.*"]` |

Rules (`deletion`, `non_fast_forward`), enforcement (`active`) and the one bypass actor (app
`4911635`, `avenue-z-v1-tag-advance`, `always`) are unchanged. The PUT body was built from the live
ruleset with only `include` replaced. There is **no `creation` rule**, so `advance-v1` can still cut
the next point tag. This also closes PR #84 review finding 3: `v1.0.0`–`v1.5.0`, the rollback refs
consumers pin to, could until now be deleted or force-moved by anyone with write access.

**Verified by refusal, not by reading the config back:**

| Probe (non-bypass force-push to `origin/main~1`) | Result |
|---|---|
| `python-ci-v1` | refused, `GH013 … Cannot force-push to this tag` |
| `python-ci-v1.0.0` | refused, `GH013 … Cannot force-push to this tag` |
| `v1.5.0` (the `refs/tags/v1.*` pattern) | **not probed**; the force-push was blocked locally before it was sent. The pattern is present in the ruleset read-back |

**Step 6 was left to the next ordinary push to `main`, and the re-run was deliberately skipped.**
`advance-v1`'s `decide` step has no "already at the target" exit. Re-running the failed advance
would therefore cut `v1.6.0` and `python-ci-v1.1.0` on the same commit as `v1.5.0` and
`python-ci-v1.0.0`. The point-tag patterns now block deletion, so those duplicates would be
permanent. Adding that exit is a follow-up, not done here.
