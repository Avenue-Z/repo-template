# Security

## Reporting

Email **paul.ramirez@avenuez.com**. Do not open a public issue.

## Never commit credentials

Service-account JSON, API keys, tokens, `.env.local` — none of it belongs in git.

`.gitignore` blocks the credential filenames we have thought of. That is a **denylist, and
denylists leak** — it is a convenience, not a control. The controls are:

| Control | Boundary |
|---|---|
| gitleaks pre-commit hook | Local, and **skippable with `--no-verify`** |
| `secret-scan` CI job | **Merge** — it fails the PR |

## The base-branch guard can be bypassed by a PR that edits the guard

`guard-base-branch` runs on `pull_request`, and GitHub Actions reads the workflow file **from the
PR's head**. The workflow checks out the base branch to get `scripts/check-base-branch.sh`, so a
PR cannot rewrite the *decision logic* it is judged by — but a PR that edits
`.github/workflows/guard-base-branch.yml` itself can still neuter the check, and with
`required_approving_review_count: 0` nobody is forced to look at it.

**So `.github/` must be code-owned.** That is what makes `--team` on `init-repo.sh` load-bearing
rather than decorative: a CODEOWNERS entry is the thing that forces a human to review a change to
the guard. Treat any PR touching `.github/workflows/` as security-relevant.

Note what this means: nothing stops the *push*. Private repos on the Free plan have no server-side
push protection. A credential can be committed, pushed to a branch, and reach the remote's object
store — where it survives even if the PR is closed unmerged.

**A key that reached the remote is burned. Rotate it.** Removing the commit is not sufficient.
