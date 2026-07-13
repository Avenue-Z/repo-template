# Avenue-Z Repo Template — Design

**Date:** 2026-07-13
**Status:** Approved for planning
**Author:** Paul Ramirez (with Claude)

## Problem

Every new Avenue-Z repo is started from scratch. A survey of six LTS repos
(`avenue-z-reporting-v2`, `aivx-reports`, `ad-spend-pacing`, `claude-marketplace`,
`drive-api-client`, `glean-chat-api-client`) shows real conventions have emerged, but
they are unwritten and unevenly applied:

- `docs/superpowers/{plans,specs}/` exists in 5 of 6 repos — the strongest de facto convention.
- Branch naming (`feat/`, `fix/`, `docs/`, `chore/`, `ci/`) is obeyed by every repo but
  written down in only one (`aivx-reports/CLAUDE.md` §8).
- The three Python repos are near-copies of each other: `src/` layout, `pyproject.toml`,
  pytest with `pythonpath=["src"]`, `tests/conftest.py` + `fakes.py`.
- Every `.gitignore` blocks credential JSON — but each blocks a *different subset*.

And there are real gaps:

- **CI exists in 1 of 6 repos** (`drive-api-client/.github/workflows/ci.yml`).
- **Zero repos lint.** No ruff, black, mypy, eslint config, or pre-commit anywhere in the org.
- **Zero repos** have LICENSE, CONTRIBUTING.md, SECURITY.md, a PR template, CODEOWNERS, or dependabot.
- **`.env.example` exists in 2 of 6.** Elsewhere env vars are documented in 500-line CLAUDE.md prose.
- **`glean-chat-api-client/.gitignore` ignores neither `.env` nor `.env.local`**, while a live
  `.env.local` sits in its working tree. `claude-marketplace` has no `.gitignore` at all.
- **No repo has branch protection** — because, as established below, it has not been possible.

## Goal

A GitHub template repository, `Avenue-Z/repo-template`, that a new project is created from in
one click plus one script, and that starts life with the org's conventions already in place.

## Key constraint discovered: the GitHub plan

Avenue-Z is on the **GitHub Free** plan (8 seats, 60 private repos). Verified against the API:

| Call | Result |
|---|---|
| `GET repos/Avenue-Z/canary-data-contracts/branches/main/protection` (private) | `403 Upgrade to GitHub Pro or make this repository public to enable this feature.` |
| `GET repos/Avenue-Z/canary-data-contracts/rulesets` (private) | `403` — same |
| `GET repos/Avenue-Z/avenue-z-reporting-v2/branches/main/protection` (public) | `404 Branch not protected` — feature available, simply unused |

Consequences:

1. **Branch protection and rulesets are unavailable on private repos on Free** — for everyone,
   including org owners. This is why no repo in the org has protection today.
2. **Branch protection is governed by the Admin *repository role*, not org ownership.** GitHub's
   repository-roles table lists "Manage branch protection rules and repository rulesets" under
   Admin only (not Read/Triage/Write/Maintain). Permissions were never the blocker; the plan is.
   *Not yet verified:* whether a repo creator in this org actually receives Admin, and how that
   interacts with Team-plan org rulesets (an org ruleset deliberately outranks a repo admin).
   Confirm on Team before writing any promise about non-owner capability into `CONTRIBUTING.md`.
3. **Org-level rulesets require GitHub Team.** Only they deliver "every repo shares the same
   rules automatically." Public-repo protection on Free is per-repo and must be applied each time.

### Decision

- `Avenue-Z/repo-template` itself is **public** (it contains no secrets by construction) and gets
  real branch protection, which proves the config works.
- Repos created from it stay **private** by default and rely on the layered enforcement below.
- **Existing private repos are not touched.** Making them public would expose full git history.
  `ad-spend-pacing` has `sa-key.json` and `client_secrets.json` in its working tree;
  `glean-chat-api-client`'s `.gitignore` does not block `.env*`; `zpress` is marked CONFIDENTIAL.
  Any future move to public requires a git-history secret audit (gitleaks/trufflehog) and
  credential rotation first. Out of scope here.
- The org ruleset is **committed as code but not applied**, ready for the day the org moves to Team.

## Branch model

```
feat/* | fix/* | docs/* | chore/* | ci/*  →  dev  →  staging  →  main
```

- **`main`** — production. Receives PRs from `staging` only.
- **`staging`** — pre-prod soak / QA. Receives PRs from `dev` only.
- **`dev`** — integration branch, and the **default branch**, so work branches and PRs target it
  without anyone having to think about it.

Note: GitHub's "Use this template" copies **only the default branch** unless "Include all
branches" is ticked, and repos created via the API omit them unless explicitly requested.
Therefore `scripts/init-repo.sh` creates and pushes `staging` and `main` itself rather than
trusting the checkbox. This makes the init script load-bearing, not a convenience.

## Enforcement layers

| Layer | Enforces | Limit |
|---|---|---|
| `.github/workflows/guard-base-branch.yml` | The full base-branch matrix (below) | Cannot stop a direct `git push origin main` |
| `.pre-commit-config.yaml` + `secret-scan` CI job | gitleaks — no credential reaches a commit or a PR | Hook is local; the CI job is the enforced one |
| `CONTRIBUTING.md` + `CLAUDE.md` Workflow Rules | The flow, commit conventions, the `git fetch --all --prune` + `git log origin/dev..HEAD` sync check | Convention only |
| `.github/rulesets/repo-ruleset.json` | Per-repo protection | Needs a public repo, or Team |
| `.github/rulesets/org-ruleset.json` | The real thing, org-wide, inherited by every repo | Needs Team |

### Base-branch matrix (`guard-base-branch.yml`)

| Head branch | Allowed base | Anything else |
|---|---|---|
| `feat/*`, `fix/*`, `docs/*`, `chore/*`, `ci/*` | `dev` | fail |
| `dev` | `staging` | fail |
| `staging` | `main` | fail |
| **any other prefix** | — | **fail closed** |

Fail-closed on an unmatched prefix is deliberate. The guard is already the weaker of the two
enforcement mechanisms — it cannot stop a direct push — so a pass-through for unrecognized branch
names would leave it enforcing nothing. A contributor who needs a new prefix adds it to the matrix
in a PR, which is the point.

### Secret scanning

`gitleaks` runs as a **pre-commit hook and a required CI job**, in the template core — not deferred
to a future move to public. The credential block in `.gitignore` is a denylist, and denylists leak;
it is a convenience, not a control. The survey found real credentials sitting in working trees
(`ad-spend-pacing`: `sa-key.json`, `client_secrets.json`) precisely because a denylist only catches
the filenames someone thought of.

This matters most on the **private** repos, which is where the daily commits happen: GitHub's own
server-side push protection is free only on **public** repositories, so private repos on Free have
no server-side net at all. The hook plus the CI job are the only backstop they get.

`scripts/apply-rulesets.sh` detects org plan and repo visibility, applies whatever is actually
possible, and **prints exactly what it skipped and why** — so nobody believes `main` is protected
when it is not. On upgrade to Team, an owner runs it once with `--org` and every repo inherits the
ruleset, with no template change and no per-repo work.

Applying an org ruleset requires the `admin:org` token scope
(`gh auth refresh -h github.com -s admin:org`); the current token has only
`gist, read:org, repo, workflow`.

**Ruleset contents must not lock out the maintainer.** A ruleset requiring one approving review on
a repo whose sole collaborator is its creator makes every PR unmergeable — the author cannot approve
their own PR. Therefore the shipped ruleset requires **a PR and passing CI, with
`required_approving_review_count: 0`**, and lists the org-admin role as a **bypass actor** for
emergencies. Teams that have two or more reviewers can raise the count in their own repo; the
template must not default to a config that bricks a one-person repo.

## Repository layout

The template core is **stack-agnostic**. The org is genuinely two-stack (Python: `ad-spend-pacing`,
`drive-api-client`, `glean-chat-api-client`; TypeScript/Vercel: `avenue-z-reporting-v2`,
`aivx-reports`), so language-specific files live in `templates/` and are copied into place by the
init script, which then deletes `templates/`. A generated repo therefore carries **zero dead files**.

```
repo-template/
├── .github/
│   ├── workflows/guard-base-branch.yml
│   ├── rulesets/{org-ruleset.json, repo-ruleset.json}
│   ├── PULL_REQUEST_TEMPLATE.md
│   ├── CODEOWNERS.tmpl                 # NOT live; init-repo.sh substitutes a real team or drops it
│   └── dependabot.yml                  # pip + npm + github-actions
├── docs/
│   ├── superpowers/{plans,specs,handoffs}/   # de facto standard, 5 of 6 repos
│   └── notes/                                # dated session notes; today they get dumped at docs/ root
├── .pre-commit-config.yaml             # gitleaks
├── scripts/
│   ├── init-repo.sh                    # <python|node> [--team <slug>]: select stack, push branches
│   └── apply-rulesets.sh               # apply what the plan allows; report what it skipped
├── templates/
│   ├── python/                         # pyproject.toml (hatchling, src/, ruff, mypy, pytest),
│   │                                   #   ci.yml (matrix), Dockerfile + .dockerignore (Cloud Run Job),
│   │                                   #   src/ + tests/conftest.py skeleton
│   └── node/                           # package.json (type: module, vitest, eslint),
│                                       #   tsconfig.json, ci.yml (npm ci → lint → typecheck → test)
├── .gitignore
├── .env.example
├── README.md
├── CLAUDE.md
├── CONTRIBUTING.md
├── SECURITY.md
└── LICENSE
```

Each `docs/` subdirectory gets a `.gitkeep` and a one-line `README.md` stating what belongs in it.

## Root files

**`.gitignore`** — union of the org's real patterns, closing the gaps found in the survey:
OS (`.DS_Store`); Python (`__pycache__/`, `.venv/`, `.pytest_cache/`, `dist/`, `build/`, `*.egg-info/`);
Node (`node_modules/`, `.next/`, `.vercel/`, `*.tsbuildinfo`); env (`.env`, `.env.local`, `.env.*`
with a `!.env.example` negation); `.claude/`; and a **credential block** —
`*service-account*.json`, `sa-key*.json`, `client_secrets.json`, `token.json`, `google-credentials.json`.

**`.env.example`** — the only committed env file. Every var declared, commented, values blank.
Modeled on `ad-spend-pacing/.env.example`, the best-annotated in the org. README setup step is
`cp .env.example .env.local`. No `.env.local` is ever tracked.

**`README.md`** — skeleton in the org's stable order (consistent across all six repos even as depth
varies from 27 to 413 lines): one-line what-this-is → Stack → Setup → Run → Tests → Deploy → Docs.
`<!-- TODO -->` markers throughout.

**`CLAUDE.md`** — short and stable: What This Is / Stack / Layout / Commands / Env / Workflow Rules /
Project Rules. Carries an explicit banner that **volatile state does not belong here** — the fix for
`aivx-reports/CLAUDE.md` §9 "Open Branches (as of 2026-06-24)" and §13 "Recent History", both already
stale, and for the 500+ line CLAUDE.md files in the two largest repos.

**`CONTRIBUTING.md`** — the branch flow, commit conventions, and the mandatory
`git fetch --all --prune` + `git log origin/dev..HEAD` sync check, lifted from `aivx-reports/CLAUDE.md` §8
(the clearest written convention in the org).

**`SECURITY.md`** — vulnerability reporting, and the never-commit-credentials rule.

**`LICENSE`** — proprietary / UNLICENSED. These are private org repos, not OSS.

**No CHANGELOG.** A changelog only pays off if maintained; `aivx-reports` keeps one inline in its README.

## CODEOWNERS: no placeholder

A CODEOWNERS entry naming a team that does not exist — or that exists but lacks **write access to
this repo** — is **silently ignored**. Per GitHub's docs: *"If you specify a user or team that
doesn't exist or has insufficient access, a code owner will not be assigned."* No error, no warning.
A `@Avenue-Z/<team>` placeholder would therefore ship a file that *looks* like enforced review and
enforces nothing — the same class of lie as the stale CLAUDE.md state this template exists to kill.

So the template ships **`.github/CODEOWNERS.tmpl`**, never a live `CODEOWNERS`. `init-repo.sh` takes
`--team <slug>`, verifies via `gh api orgs/Avenue-Z/teams/<slug>` that the team exists, and only then
writes `.github/CODEOWNERS`. Without `--team`, it **deletes the template and prints a warning** that
the repo has no code-owner review. A repo either has a real, verified owning team or is honest about
having none.

Note that team existence is necessary but not sufficient — the team must also be granted write access
to the new repo. `init-repo.sh` checks for that too and warns if the team has no write permission,
because that is the exact silent-failure case.

## Init script: idempotent, single-commit, git-rollback

`init-repo.sh` must be safe to re-run. Between "Use this template" and the first run, a new repo has
only `dev` — no `main`, no `staging` — so a script that fails halfway or is never run leaves the repo
in a half-configured state.

- **Idempotent branch creation.** Create-if-absent for `staging` and `main` (check `git rev-parse
  --verify`), never force-push. Re-running is a no-op, not a reset.
- **`set -euo pipefail`,** so a failure stops rather than continuing into a partial config.
- **Copy is verified before `templates/` is removed,** and the whole change lands as **one commit**.
- **Rollback is git.** The script runs inside a git working tree, so a failed run is undone with
  `git checkout -- . && git clean -fd`, and `templates/` remains in HEAD until the commit lands.
  A stage-to-temp-dir-then-atomically-move layer was considered and rejected: it protects against a
  failure mode git already covers, at the cost of real moving parts. On failure the script prints the
  recovery command.

## New: linting

`templates/python/pyproject.toml` ships **ruff + mypy**, and `templates/node/` ships **eslint +
`tsc --noEmit`**. No repo in the org lints today, so this is a genuine change to the day-to-day, not
just a new file: every new repo starts with a lint gate that no existing repo would pass. Accepted
deliberately. Existing repos are not retrofitted as part of this work.

## Testing / success criteria

1. `scripts/init-repo.sh python` in a scratch clone produces a repo whose `pytest -q` and `ruff check`
   pass on the skeleton, with no `templates/` directory left behind.
2. `scripts/init-repo.sh node` likewise for `npm test`, `npm run lint`, `tsc --noEmit`.
3. Both leave `main`, `staging`, `dev` pushed to origin, with `dev` as the default branch.
4. `guard-base-branch.yml` fails a PR from `feat/x` → `main`, passes `feat/x` → `dev`, passes
   `dev` → `staging`, and **fails an unmatched prefix** (`wip/x` → `dev`) — the fail-closed case.
5. `apply-rulesets.sh` on the public template repo results in `main` reporting protected via
   `gh api repos/Avenue-Z/repo-template/branches/main/protection` — **and then the maintainer can
   still open and merge a PR into it.** Protection that bricks the repo is a failed criterion, not a
   passed one.
6. `apply-rulesets.sh` against a private repo on Free exits 0 and prints a clear explanation that
   protection was skipped and why — it does not fail silently or claim success.
7. Re-running `init-repo.sh` on an already-initialized repo is a no-op that exits 0 — it does not
   duplicate, reset, or force-push branches.
8. `init-repo.sh --team <nonexistent>` refuses to write a live `CODEOWNERS`; with no `--team` it
   removes `CODEOWNERS.tmpl` and warns. No generated repo ever ships an inert CODEOWNERS.
9. Committing a fake AWS/Google credential to the skeleton is blocked by the gitleaks pre-commit hook,
   and the `secret-scan` CI job fails if it reaches a PR.

## Out of scope

- Retrofitting the six reference repos (or the other 54) with any of this.
- The git-history secret audit and credential rotation that a future move to public would require.
  (Note: gitleaks in the template prevents *new* leaks. It does not clean *existing* history.)
- Upgrading the org to GitHub Team. The design is ready for it; the decision is Paul's.

## Review log — 2026-07-13

Spec revised after review. Accepted: full base-branch matrix + fail-closed on unmatched prefix;
idempotent re-runnable `init-repo.sh`; gitleaks moved into the template core rather than deferred;
`CODEOWNERS.tmpl` with verified-team substitution instead of an inert placeholder; ruleset configured
so it cannot lock out a sole maintainer.

Rejected: staging-directory + atomic-move for the `templates/` copy. The script runs in a git working
tree, which already provides the rollback (`git checkout -- . && git clean -fd`); the added machinery
would guard a failure mode git covers. Mitigated instead with `set -euo pipefail`, verify-before-delete,
a single commit, and a printed recovery command.

Verified against GitHub docs, not assumed: CODEOWNERS silently ignores nonexistent or
insufficient-access owners; "Manage branch protection rules and repository rulesets" is an Admin-role
permission, not org-owner-exclusive. Left explicitly unverified: whether a repo creator in this org
receives Admin, and Team-plan org-ruleset/repo-admin interaction — to be confirmed before any promise
about it lands in `CONTRIBUTING.md`.
