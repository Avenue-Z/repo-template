# Contributing

## Branch flow

    feat/* | fix/* | docs/* | chore/* | ci/* | dependabot/*  →  dev  →  staging  →  main

- **`dev`** — integration branch, and the default. Open your PR here.
- **`staging`** — pre-prod soak / QA. Receives PRs from `dev` only.
- **`main`** — production. Receives PRs from `staging` only.

`guard-base-branch` fails any PR whose base is wrong for its head, and **fails closed on an
unrecognized branch prefix**. Need a new prefix? Add it to the matrix in a PR.

## Never push directly to main

Every change reaches `main` through the chain above. No exceptions.

## Start every session by syncing

    git fetch --all --prune
    git log origin/dev..HEAD        # what you have that origin does not

## Commits

`feat:` `fix:` `docs:` `chore:` `ci:` `test:` — imperative mood, one logical change.

## Before you open a PR

- Tests pass.
- Lint passes (`ruff check` / `npm run lint`).
- No credentials. `secret-scan` will fail the PR; a key that reached the remote is **burned and
  must be rotated**, even if the PR is never merged. See SECURITY.md.
