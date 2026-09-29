# 2026-09-29 — Fleet migration roadmap, ordered by recency + ease

Which repos still need `checks@v1` and `python-ci@python-ci-v1` callers, and in what order. This
**replaces the order in spec §3 for phases C–E**
(`template-docs/specs/2026-09-09-reusable-workflows-design.md`). The pilot, the per-repo hazards, and
the phase letters already cited in PRs stay as the spec has them. The spec's 11-repo inventory dates
from 2026-09-09. Five repos that billed minutes this month are not in it, so this note starts from a
fresh scan of every non-archived Avenue-Z repo.

Everything below was read on 2026-09-29 and **will go stale**. Re-run the scan before trusting it next
month.

## The key

| Axis | 1 | 2 | 3 |
|---|---|---|---|
| **Recency**: last human commit on the default branch (Dependabot excluded) | Hot, within 10 days | Warm, within 30 days | Cold, older |
| **Ease** | Easy: `ci.yml` is byte-identical to a version the template shipped, or the stack is not Python and only the `checks` caller applies | Medium: `ci.yml` was edited (extra jobs, a pinned version), no hazard | Hard: the repo gains a gate it has never run, or is public with a live ruleset |

**Score = recency + ease. Lower goes first.** Ties go to the repo that billed more minutes in September,
because that's where the saving is. Two exceptions:

- **The pilot is pinned, not scored.** `data-warehouse` goes first for the reasons in spec §3: its
  governance files are unmodified, it's private, and it's the largest consumer. B's exit criteria must be
  met before any wave starts.
- **A blocked lane.** A repo whose CI installs the private packages with a personal access token can't
  take the `python-ci` caller: `python-ci.yml` accepts no secrets, by design. It takes the `checks` caller
  now and the `ci` caller once the private-packages work lands.

## Where the fleet stands

- **21 repos are template-derived.** 4 are done: `aeo-llm-analysis`, `pr-proof-engine`,
  `engineer-copilot` and `assembly-line`. The last three were created 2026-09-26 to 09-28 and came out of
  `init-repo.sh` already migrated.
- **11 are on the old layout and 4 are half-migrated** (a `checks` caller with an inline `ci.yml`).
- `avenue-z-reporting-v2` is Phase F and out of scope. 17 more repos run their own CI and were never
  template-derived. They're out of scope too, per `docs/ADOPTION.md`'s no-retrofit rule.
- **The governance files are unmodified everywhere that matters.** Every old-layout repo's
  `guard-base-branch.yml`, `sca.yml`, `secret-scan.yml` and gate scripts match, by git blob SHA, a
  version `repo-template` shipped. The one exception is `sca-gate.sh`, and it is a single blob
  (`4f9c4f4`) shared by all nine repos that carry it: one fleet-wide copy, not per-repo drift. Ease is
  therefore decided by `ci.yml` and the hazards, not by the governance files.

## The order

"Per PR push" is billed minutes for one push to a PR, computed from each workflow's shape (jobs × matrix
legs, each rounded up to a minute). It is not a measurement. The one measured figure is `data-warehouse`'s
September median of 11. Old-layout `ci.yml`, `sca.yml` and `secret-scan.yml` also run on pushes to
`dev`, `staging` and `main`. The migration cuts those to `main`, which the per-push numbers leave out
(33% of `data-warehouse`'s September minutes).

| Wave | Repo | Recency | Ease | Score | Sept min | Per PR push | What the PR carries |
|---|---|---|---|---|---|---|---|
| **0** | `data-warehouse` | Hot (09-22; 61 human PRs merged in 30 days) | Medium | pinned | 1,070 | 10 → 4 | Both callers, `["3.11"]` from the Dockerfile. Keep `dbt-parse` and add it to `ci`'s `needs:`. Fold `typecheck` into the check command if `make check` already runs mypy. Group Dependabot. Tell its maintainers first |
| **1** | `pr-annual-eoy-decks` | Hot (09-21) | Easy | 2 | 125 | 5 → 3 | The `ci` caller only; its `ci.yml` is a template version |
| 1 | `postcall-action-items` | Hot (09-29; 33 in 30 days) | Easy, `checks` only | 2 | 73 | 7 → 5 | The `checks` caller. `ci` stays inline (blocked lane) and its `push:` is trimmed to `[main]` |
| 1 | `az-media-hits` | Hot (09-29) | Easy | 2 | 58 | 4 → 2 | The `checks` caller. Next stack: `ci` stays inline, `push:` trimmed to `[main]` |
| **2** | `content-calendar-deck` | Warm (09-17) | Easy | 3 | 131 | 5 → 3 | The `ci` caller only |
| 2 | `rippling-asana-pto` | Warm (09-08) | Easy | 3 | 95 | 8 → 3 | Both callers, `["3.11"]` |
| 2 | `announcement-recapping` | Warm (09-02) | Easy | 3 | 89 | 8 → 3 | Both callers, `["3.11"]` |
| **3** | `dash-social-connection` | Warm (09-15) | Medium | 4 | 38 | 7 → 4 | Both callers, `["3.13"]` from its Dockerfile. `ci.yml` was edited; `contract.yml` is untouched. It has 2 lockfiles, so SCA really scans |
| 3 | `sf-sb-automation` | Cold (08-03) | Easy | 4 | 26 | 8 → 3 | Both callers, `["3.11"]` |
| 3 | `az-utm-generator` | Cold (07-29) | Easy | 4 | 13 | 4 → 2 | The `checks` caller; Next stack |
| **4** | `os-performance-decks` | Warm (09-15) | Hard | 5 | 0 | 1 → 1 | Only an edited `guard-base-branch.yml` today. It **gains** the secret scan (full history) and SCA for the first time, with no stack for SCA to read. Saves no minutes; the value is the gates. Talk to its owner first |
| 4 | `noble-clone` | Cold (08-27) | Hard | 6 | 4 | 4 → 4 | Spec Phase E. It has no `sca-policy.json`, so it gets the strictest tier on a tree never scanned, and runs Bandit for the first time. No Dockerfile, so `python-versions` has to be chosen. `drive-api-client` is in an optional extra, so `python-ci`'s `.[dev]` install doesn't need it |
| 4 | `data-contract` | Cold (08-04) | Hard | 6 | 26 (public, $0) | 6 → 3 | Spec Phase E: public with a live ruleset, so the windowed or overlap ordering applies (Open item 10). CI tests `3.13` while its Dockerfile is `3.11`, so pick one. Saves no money |

### Blocked lane: the `ci` caller waits on private packages

| Repo | Recency | State | Sept min | Per PR push | Blocker |
|---|---|---|---|---|---|
| `comment-engagement` | Hot (09-29) | `checks` done | 756 | 4 → 4 | Its CI installs `drive-api-client` and `glean-chat-api-client` with a fine-grained PAT secret. Its inline `ci` is already 2 jobs, so migrating it saves nothing yet |
| `client-satisfaction-report` | Hot (09-28) | `checks` done; **Actions disabled** | 998 | 4 → 4 | Same PAT pattern. Actions is switched off at the repo level, so someone has to decide whether it comes back on before anything else happens here |
| `postcall-action-items` | Hot | `checks` in Wave 1 | — | — | Both packages are regular dependencies from `git+https`, and `ci.yml` has no credential for them. How its CI installs them is **unverified**: its last 60 `ci` runs were all refused by billing |

**Payoff.** Waves 0–3 cover 1,718 of September's private minutes, and September was blocked for about
twelve days. The per-push cuts are 40–70%, plus the push runs. That's roughly 900–1,100 minutes a month
at September's activity. **An estimate, not a measurement.** Phase B's durations are what confirm it.

## Every migration PR

- Copy the template's current Python caller verbatim, and set `python-versions` to the Dockerfile's
  version. `test_python_ci.sh` enforces that pairing in the template, and nothing enforces it in the
  repo.
- The `checks` and `python-ci` jobs grant `id-token: write`. Without it the run is a `startup_failure`
  with no check at all.
- Delete `guard-base-branch.yml`, `sca.yml` and `secret-scan.yml`. Leave `scripts/*.sh` in place until
  Phase E's cleanup (spec Open item 9).
- Trim `push:` to `[main]` on any inline workflow that stays.
- Add Dependabot grouping where the repo predates it.
- Check what the repo commits for osv-scanner to read (spec Open item 15). Most of these Python repos
  have no lockfile, so the SCA half of `checks` scans nothing there, before and after.
- Tell whoever works in the repo before opening the PR (spec §3).

## Outside this roadmap

- **The private-packages spec's consumer inventory is missing three repos**: `comment-engagement`,
  `client-satisfaction-report` and `postcall-action-items`. Two of them put a PAT in CI, which is
  the pattern that spec exists to remove.

## How this was measured

- Sept minutes: the org billing usage API, Actions `Minutes` items, grouped by repository.
- Layout and byte-identity: each repo's git tree (blob SHAs) compared against every blob `git log --all`
  finds for the same path in `repo-template`, and for `ci.yml` against every version of
  `templates/<stack>/.github/workflows/ci.yml`.
- Recency: the newest commit on the default branch not authored by a bot. Human-PR counts come from the
  search API, which rate-limited after two repos, so they appear only for `data-warehouse` and
  `postcall-action-items`.
