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
