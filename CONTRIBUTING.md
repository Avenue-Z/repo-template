# Contributing

## Branch flow

    feat/* | fix/* | docs/* | chore/* | ci/* | dependabot/*  →  dev  →  staging  →  main

- **`dev`** — integration branch, and the default. Open your PR here.
- **`staging`** — pre-prod soak / QA. Receives PRs from `dev` only.
- **`main`** — production. Receives PRs from `staging` only.

`guard-base-branch` fails any PR whose base is wrong for its head, and **fails closed on an
unrecognized branch prefix**. Need a new prefix? Add it to the `case` statement in
`scripts/check-base-branch.sh` (and to the matrix above) in a PR.

The guard reads its decision script from the **base** branch, so a PR cannot rewrite the rule it
is being judged against. It cannot, however, defend against a PR that edits
`.github/workflows/guard-base-branch.yml` itself — Actions runs the workflow file from the PR's
head. Treat `.github/` as code-owned and review changes to it. See `SECURITY.md`.

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

`scripts/apply-rulesets.sh --org` applies a ruleset to **every repository in the org**. It lists
them and demands an explicit `--yes` first.

## Commits

`feat:` `fix:` `docs:` `chore:` `ci:` `test:` — imperative mood, one logical change.

## Before you open a PR

- Tests pass.
- Lint passes (`ruff check` / `npm run lint`).
- No credentials. `secret-scan` will fail the PR; a key that reached the remote is **burned and
  must be rotated**, even if the PR is never merged. See SECURITY.md.
