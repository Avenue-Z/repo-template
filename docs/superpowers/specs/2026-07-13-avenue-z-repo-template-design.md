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
2. **Repo-admin, not org-owner, is the permission that governs branch protection.** Whoever
   creates a repo in the org becomes its admin. So once the plan allows it, non-owners *can*
   protect their own repos. Permissions were never the blocker; the plan is.
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
| `.github/workflows/guard-base-branch.yml` | Fails any PR whose base is wrong for its head: `feat/*`→`dev`; only `dev`→`staging`; only `staging`→`main` | Cannot stop a direct `git push origin main` |
| `CONTRIBUTING.md` + `CLAUDE.md` Workflow Rules | The flow, commit conventions, the `git fetch --all --prune` + `git log origin/dev..HEAD` sync check | Convention only |
| `.github/rulesets/repo-ruleset.json` | Per-repo protection | Needs a public repo, or Team |
| `.github/rulesets/org-ruleset.json` | The real thing, org-wide, inherited by every repo | Needs Team |

`scripts/apply-rulesets.sh` detects org plan and repo visibility, applies whatever is actually
possible, and **prints exactly what it skipped and why** — so nobody believes `main` is protected
when it is not. On upgrade to Team, an owner runs it once with `--org` and every repo inherits the
ruleset, with no template change and no per-repo work.

Applying an org ruleset requires the `admin:org` token scope
(`gh auth refresh -h github.com -s admin:org`); the current token has only
`gist, read:org, repo, workflow`.

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
│   ├── CODEOWNERS                      # @Avenue-Z/<team> placeholder
│   └── dependabot.yml                  # pip + npm + github-actions
├── docs/
│   ├── superpowers/{plans,specs,handoffs}/   # de facto standard, 5 of 6 repos
│   └── notes/                                # dated session notes; today they get dumped at docs/ root
├── scripts/
│   ├── init-repo.sh                    # <python|node>: select stack, push branches
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
4. `guard-base-branch.yml` fails a PR from `feat/x` targeting `main`, and passes one targeting `dev`.
5. `apply-rulesets.sh` on the public template repo results in `main` reporting protected via
   `gh api repos/Avenue-Z/repo-template/branches/main/protection`.
6. `apply-rulesets.sh` against a private repo on Free exits 0 and prints a clear explanation that
   protection was skipped and why — it does not fail silently or claim success.

## Out of scope

- Retrofitting the six reference repos (or the other 54) with any of this.
- The git-history secret audit and credential rotation that a future move to public would require.
- Upgrading the org to GitHub Team. The design is ready for it; the decision is Paul's.
