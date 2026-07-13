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

Note what this means: nothing stops the *push*. Private repos on the Free plan have no server-side
push protection. A credential can be committed, pushed to a branch, and reach the remote's object
store — where it survives even if the PR is closed unmerged.

**A key that reached the remote is burned. Rotate it.** Removing the commit is not sufficient.
