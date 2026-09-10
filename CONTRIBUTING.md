# Contributing

## Branch flow

    feat/* | fix/* | docs/* | chore/* | ci/* | dependabot/* | perf/* | refactor/* | test/*  →  dev  →  staging  →  main

- **`dev`** — integration branch. **Open your PR here.**

  Note the repo's *GitHub default branch* is `main`, not `dev`. That is deliberate: Vercel (and
  most tooling) takes the **production** branch from the repository default, so a repo defaulting
  to `dev` would deploy every merged PR straight to production. The cost is that a PR opened in the
  GitHub UI targets `main` — **change the base to `dev`** with the dropdown next to the title, or
  use `gh pr create --base dev`. If you forget, the `checks` job fails the PR loudly; it re-runs
  when you change the base.
- **`staging`** — pre-prod soak / QA. Receives PRs from `dev` only.
- **`main`** — production. Receives PRs from `staging` only.

The base-branch guard — the first step of the `checks` job — fails any PR whose base is wrong
for its head, and **fails closed on an
unrecognized branch prefix**. The matrix is enforced centrally and the guard's own error output is its
authoritative statement — if this list and that message ever disagree, the message is right. Need a new
prefix? Open a PR against `Avenue-Z/repo-template`.

The three gate scripts are staged from `Avenue-Z/repo-template` at the ref `checks.yml` was
**called at**, so in a repo that calls this workflow, a PR cannot supply them. In
`repo-template` itself they come from the **workspace** instead — a deliberate trade-off, not an
oversight; see `SECURITY.md` for why and what it costs. Either way, this cannot defend against a
PR that edits `.github/workflows/checks.yml` itself — Actions runs the workflow file from the
PR's head, and **nothing in this repo's configuration forces anyone to review that.** `CODEOWNERS`
routes such a PR to a reviewer; it does not require their approval. Review any PR touching
`.github/` by convention, and read `SECURITY.md` before assuming you are protected from one.

## Never push directly to main

Every change reaches `main` through the chain above. No exceptions.

## Start every session by syncing

    git fetch --all --prune
    git log origin/dev..HEAD        # what you have that origin does not

## Repo setup scripts change real GitHub state

`scripts/init-repo.sh --team <slug>` does not just write `.github/CODEOWNERS` — if the team lacks
write access to this repo, it **grants the team push (write) access** on GitHub. That is a real
permission change, made because GitHub silently ignores a CODEOWNERS entry naming a team without
write access. Omit `--team` if you do not want it.

`scripts/apply-rulesets.sh` only ever touches **the repo you are standing in**.

The org-wide apply is a **separate script**, `scripts/apply-org-ruleset.sh`, and it is meant to be
awkward. It applies a ruleset to **every repository in Avenue-Z**, so it has no `--yes`, no
environment-variable override, and no non-interactive path at all — it cannot run from CI, and
there is no one-liner to replay out of your shell history. It lists every repo it would hit and
makes you type a challenge phrase that names the live repo count. If you find yourself wanting to
automate it, that is the feeling the design is for.

### Governance changes need a companion marketplace PR

`Avenue-Z/claude-marketplace` ships the `repo-template-first` skill, which describes this repo's
workflows and what a generated repo contains. It is a **third copy** of these conventions, after the
template and the repos derived from it. Nothing syncs it automatically and nothing is going to: at this
size a sync mechanism would cost more than the drift does. So it is a rule instead — **a PR that
changes the governance workflows, the branch matrix, or what `init-repo.sh` generates opens a companion
PR against `Avenue-Z/claude-marketplace` in the same sitting.**

## Commits

`feat:` `fix:` `docs:` `chore:` `ci:` `test:` — imperative mood, one logical change.

## Before you open a PR

- `make check` passes — the correctness gate (lint + typecheck + tests, plus `build` on next).
  ci.yml runs the same target, so a green `make check` is the same gate the PR faces.
- No credentials. The `secret-scan` step of `checks` will fail the PR; a key that reached the
  remote is **burned and
  must be rotated**, even if the PR is never merged. See SECURITY.md.
