# <!-- TODO: repo-name -->

<!-- TODO: one sentence. What is this and who is it for? -->

## Stack
<!-- TODO -->

## Setup

    git clone git@github.com:Avenue-Z/<repo>.git && cd <repo>
    cp .env.example .env.local            # then fill it in
    <!-- TODO: install command -->
    pipx install pre-commit               # or: brew install pre-commit
    pre-commit install                    # installs the gitleaks hook

`pre-commit` is installed standalone rather than as a project dependency so the same line works
on both stacks. (The Python template also ships it in its `dev` extras, so
`pip install -e ".[dev]"` gets you it for free.)

## Run
<!-- TODO -->

## Tests
<!-- TODO -->

## Deploy
<!-- TODO -->

## Docs

- `docs/superpowers/specs/` — design specs
- `docs/superpowers/plans/` — implementation plans
- `docs/superpowers/handoffs/` — volatile state: in-flight work, open branches, "as of" notes.
  This is where it goes, NOT in `CLAUDE.md`.
- `docs/notes/` — dated working notes
- `CONTRIBUTING.md` — branch flow. **Never push directly to `main`.**

## Repo setup scripts (template-derived repos)

- `scripts/init-repo.sh <python|node> [--team <slug>]` — selects the stack and creates
  `dev`/`staging`/`main`. **`--team` changes GitHub permissions:** if the named team exists but
  lacks write access to this repo, the script **grants it push (write) access**
  (`PUT orgs/Avenue-Z/teams/<slug>/repos/<owner>/<repo>`) before writing `.github/CODEOWNERS`.
  It does this rather than merely warning, because GitHub *silently ignores* a CODEOWNERS entry
  naming a team without write access — a warning nobody actions leaves an inert file that looks
  like enforced review and enforces nothing. Granting needs repo-admin or org-owner rights; if
  it fails, the script refuses to write CODEOWNERS at all. Omit `--team` and no permissions are
  touched.
- `scripts/apply-rulesets.sh [--org [--yes]] [--dry-run]` — applies branch protection where the
  plan allows and prints what it skipped. `--org` targets **every repo in the org**; it lists
  them and requires an explicit confirmation first.
